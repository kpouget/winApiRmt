/*
 * Linux VMBus Client Driver for Windows API Remoting
 *
 * This driver provides the guest side of the API remoting framework,
 * communicating with the Windows host via VMBus.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/slab.h>
#include <linux/mm.h>
#include <linux/hyperv.h>
#include <linux/device.h>
#include <linux/cdev.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/wait.h>
#include <linux/spinlock.h>
#include <linux/completion.h>

#include "../../common/protocol.h"

#define DRIVER_NAME "winapi_client"
#define DEVICE_NAME "winapi"
#define CLASS_NAME  "winapi_remoting"

/* VMBus device GUID - must match host driver */
#define HV_WINAPI_GUID "{6ac83d8f-6e16-4e5c-ab3d-fd8c5a4b7e21}"
static const uuid_le winapi_guid = UUID_LE(0x6ac83d8f, 0x6e16, 0x4e5c,
                                           0xab, 0x3d, 0xfd, 0x8c, 0x5a, 0x4b, 0x7e, 0x21);

/* Device context structure */
struct winapi_device {
    struct hv_device *hv_dev;
    struct vmbus_channel *channel;

    /* Character device interface */
    dev_t dev_number;
    struct class *dev_class;
    struct device *device;
    struct cdev char_dev;

    /* Request handling */
    struct completion channel_ready;
    spinlock_t request_lock;
    atomic_t next_request_id;

    /* Pending requests */
    struct list_head pending_requests;
    wait_queue_head_t response_queue;
};

/* Pending request structure */
struct pending_request {
    struct list_head list;
    u64 request_id;
    winapi_message_t *response;
    struct completion response_ready;
    int error;
};

/* IOCTL definitions */
#define WINAPI_IOC_MAGIC 'W'
#define WINAPI_IOC_ECHO          _IOWR(WINAPI_IOC_MAGIC, 1, struct winapi_ioctl_echo)
#define WINAPI_IOC_BUFFER_TEST   _IOWR(WINAPI_IOC_MAGIC, 2, struct winapi_ioctl_buffer_test)
#define WINAPI_IOC_PERF_TEST     _IOWR(WINAPI_IOC_MAGIC, 3, struct winapi_ioctl_perf_test)

/* IOCTL structures */
struct winapi_ioctl_echo {
    char input[WINAPI_MAX_INLINE_DATA];
    char output[WINAPI_MAX_INLINE_DATA];
    u32 input_len;
    u32 output_len;
};

struct winapi_ioctl_buffer_test {
    void __user *buffers[WINAPI_MAX_BUFFERS];
    u32 buffer_sizes[WINAPI_MAX_BUFFERS];
    u32 buffer_count;
    u32 operation;
    u32 test_pattern;
    u64 bytes_processed;
    u32 checksum;
    int status;
};

struct winapi_ioctl_perf_test {
    u32 test_type;
    u32 iterations;
    u64 target_bytes;
    void __user *buffers[WINAPI_MAX_BUFFERS];
    u32 buffer_sizes[WINAPI_MAX_BUFFERS];
    u32 buffer_count;
    u64 min_latency_ns;
    u64 max_latency_ns;
    u64 avg_latency_ns;
    u64 throughput_mbps;
    u32 iterations_completed;
};

static struct winapi_device *g_winapi_dev = NULL;

/* Forward declarations */
static int winapi_probe(struct hv_device *hv_dev, const struct hv_vmbus_device_id *dev_id);
static void winapi_remove(struct hv_device *hv_dev);
static void winapi_channel_callback(void *context);

/* VMBus driver structure */
static const struct hv_vmbus_device_id winapi_id_table[] = {
    { HV_WINAPI_GUID, },
    { },
};
MODULE_DEVICE_TABLE(vmbus, winapi_id_table);

static struct hv_driver winapi_vmbus_driver = {
    .name = DRIVER_NAME,
    .id_table = winapi_id_table,
    .probe = winapi_probe,
    .remove = winapi_remove,
    .driver = {
        .probe_type = PROBE_PREFER_ASYNCHRONOUS,
    },
};

/* Character device file operations */
static int winapi_open(struct inode *inode, struct file *file)
{
    if (!g_winapi_dev) {
        return -ENODEV;
    }

    file->private_data = g_winapi_dev;
    return 0;
}

static int winapi_release(struct inode *inode, struct file *file)
{
    return 0;
}

/* Send message and wait for response */
static int winapi_send_message_sync(struct winapi_device *dev,
                                   winapi_message_t *request,
                                   winapi_message_t *response)
{
    struct pending_request *pending;
    unsigned long flags;
    int ret;

    /* Allocate pending request structure */
    pending = kzalloc(sizeof(*pending), GFP_KERNEL);
    if (!pending) {
        return -ENOMEM;
    }

    /* Initialize pending request */
    init_completion(&pending->response_ready);
    pending->request_id = request->header.request_id;
    pending->response = response;
    pending->error = 0;

    /* Add to pending list */
    spin_lock_irqsave(&dev->request_lock, flags);
    list_add_tail(&pending->list, &dev->pending_requests);
    spin_unlock_irqrestore(&dev->request_lock, flags);

    /* Send request */
    ret = vmbus_sendpacket(dev->channel, request, sizeof(*request),
                          request->header.request_id,
                          VM_PKT_DATA_INBAND, 0);
    if (ret) {
        pr_err("winapi: Failed to send request: %d\n", ret);
        goto cleanup;
    }

    /* Wait for response */
    ret = wait_for_completion_timeout(&pending->response_ready,
                                     msecs_to_jiffies(5000));
    if (ret == 0) {
        pr_err("winapi: Request timeout\n");
        ret = -ETIMEDOUT;
        goto cleanup;
    }

    ret = pending->error;

cleanup:
    /* Remove from pending list */
    spin_lock_irqsave(&dev->request_lock, flags);
    list_del(&pending->list);
    spin_unlock_irqrestore(&dev->request_lock, flags);

    kfree(pending);
    return ret;
}

/* Echo IOCTL handler */
static long winapi_ioctl_echo(struct winapi_device *dev,
                             struct winapi_ioctl_echo __user *user_arg)
{
    struct winapi_ioctl_echo arg;
    winapi_message_t request, response;
    winapi_echo_request_t *echo_req;
    winapi_echo_response_t *echo_resp;
    int ret;

    if (copy_from_user(&arg, user_arg, sizeof(arg))) {
        return -EFAULT;
    }

    if (arg.input_len > sizeof(echo_req->input_data)) {
        return -EINVAL;
    }

    /* Build request */
    memset(&request, 0, sizeof(request));
    request.header.magic = WINAPI_MESSAGE_MAGIC;
    request.header.version = WINAPI_PROTOCOL_VERSION;
    request.header.message_type = WINAPI_MSG_REQUEST;
    request.header.api_id = WINAPI_API_ECHO;
    request.header.request_id = atomic_inc_return(&dev->next_request_id);
    request.header.inline_size = sizeof(winapi_echo_request_t);
    request.header.timestamp = ktime_get_ns();

    echo_req = (winapi_echo_request_t *)request.inline_data;
    echo_req->input_len = arg.input_len;
    memcpy(echo_req->input_data, arg.input, arg.input_len);

    /* Send request and get response */
    ret = winapi_send_message_sync(dev, &request, &response);
    if (ret) {
        return ret;
    }

    if (response.header.error_code != WINAPI_OK) {
        return -EIO;
    }

    /* Copy response back to user */
    echo_resp = (winapi_echo_response_t *)response.inline_data;
    arg.output_len = min(echo_resp->output_len, (u32)sizeof(arg.output));
    memcpy(arg.output, echo_resp->output_data, arg.output_len);

    if (copy_to_user(user_arg, &arg, sizeof(arg))) {
        return -EFAULT;
    }

    return 0;
}

/* Buffer test IOCTL handler */
static long winapi_ioctl_buffer_test(struct winapi_device *dev,
                                    struct winapi_ioctl_buffer_test __user *user_arg)
{
    struct winapi_ioctl_buffer_test arg;
    winapi_message_t request, response;
    winapi_buffer_test_request_t *buf_req;
    winapi_buffer_test_response_t *buf_resp;
    struct page **pages[WINAPI_MAX_BUFFERS];
    int page_counts[WINAPI_MAX_BUFFERS];
    int i, j, ret;

    if (copy_from_user(&arg, user_arg, sizeof(arg))) {
        return -EFAULT;
    }

    if (arg.buffer_count == 0 || arg.buffer_count > WINAPI_MAX_BUFFERS) {
        return -EINVAL;
    }

    memset(pages, 0, sizeof(pages));
    memset(page_counts, 0, sizeof(page_counts));

    /* Pin user pages */
    for (i = 0; i < arg.buffer_count; i++) {
        unsigned long start = (unsigned long)arg.buffers[i];
        unsigned long end = start + arg.buffer_sizes[i];
        int nr_pages = (end - (start & PAGE_MASK) + PAGE_SIZE - 1) >> PAGE_SHIFT;

        pages[i] = kcalloc(nr_pages, sizeof(struct page *), GFP_KERNEL);
        if (!pages[i]) {
            ret = -ENOMEM;
            goto cleanup_pages;
        }

        ret = get_user_pages_fast(start & PAGE_MASK, nr_pages,
                                 FOLL_WRITE, pages[i]);
        if (ret < nr_pages) {
            pr_err("winapi: Failed to pin user pages: %d\n", ret);
            if (ret > 0) {
                for (j = 0; j < ret; j++) {
                    put_page(pages[i][j]);
                }
            }
            kfree(pages[i]);
            pages[i] = NULL;
            ret = -EFAULT;
            goto cleanup_pages;
        }
        page_counts[i] = nr_pages;
    }

    /* Build request */
    memset(&request, 0, sizeof(request));
    request.header.magic = WINAPI_MESSAGE_MAGIC;
    request.header.version = WINAPI_PROTOCOL_VERSION;
    request.header.message_type = WINAPI_MSG_REQUEST;
    request.header.api_id = WINAPI_API_BUFFER_TEST;
    request.header.request_id = atomic_inc_return(&dev->next_request_id);
    request.header.buffer_count = arg.buffer_count;
    request.header.inline_size = sizeof(winapi_buffer_test_request_t);
    request.header.timestamp = ktime_get_ns();

    buf_req = (winapi_buffer_test_request_t *)request.inline_data;
    buf_req->operation = arg.operation;
    buf_req->test_pattern = arg.test_pattern;

    /* Set up buffer descriptors with guest physical addresses */
    for (i = 0; i < arg.buffer_count; i++) {
        request.buffers[i].guest_pa = page_to_pfn(pages[i][0]) << PAGE_SHIFT;
        request.buffers[i].size = arg.buffer_sizes[i];
        request.buffers[i].flags = WINAPI_BUFFER_READWRITE;
    }

    /* Send request and get response */
    ret = winapi_send_message_sync(dev, &request, &response);
    if (ret) {
        goto cleanup_pages;
    }

    /* Copy response back to user */
    if (response.header.error_code == WINAPI_OK) {
        buf_resp = (winapi_buffer_test_response_t *)response.inline_data;
        arg.bytes_processed = buf_resp->bytes_processed;
        arg.checksum = buf_resp->checksum;
        arg.status = buf_resp->status;
        ret = 0;
    } else {
        arg.status = response.header.error_code;
        ret = -EIO;
    }

    if (copy_to_user(user_arg, &arg, sizeof(arg))) {
        ret = -EFAULT;
    }

cleanup_pages:
    /* Unpin pages */
    for (i = 0; i < WINAPI_MAX_BUFFERS; i++) {
        if (pages[i]) {
            for (j = 0; j < page_counts[i]; j++) {
                put_page(pages[i][j]);
            }
            kfree(pages[i]);
        }
    }

    return ret;
}

/* Performance test IOCTL handler */
static long winapi_ioctl_perf_test(struct winapi_device *dev,
                                  struct winapi_ioctl_perf_test __user *user_arg)
{
    struct winapi_ioctl_perf_test arg;
    winapi_message_t request, response;
    winapi_perf_test_request_t *perf_req;
    winapi_perf_test_response_t *perf_resp;
    struct page **pages[WINAPI_MAX_BUFFERS];
    int page_counts[WINAPI_MAX_BUFFERS];
    int i, j, ret;

    if (copy_from_user(&arg, user_arg, sizeof(arg))) {
        return -EFAULT;
    }

    memset(pages, 0, sizeof(pages));
    memset(page_counts, 0, sizeof(page_counts));

    /* Pin user pages if buffers provided */
    if (arg.buffer_count > 0) {
        for (i = 0; i < arg.buffer_count; i++) {
            unsigned long start = (unsigned long)arg.buffers[i];
            unsigned long end = start + arg.buffer_sizes[i];
            int nr_pages = (end - (start & PAGE_MASK) + PAGE_SIZE - 1) >> PAGE_SHIFT;

            pages[i] = kcalloc(nr_pages, sizeof(struct page *), GFP_KERNEL);
            if (!pages[i]) {
                ret = -ENOMEM;
                goto cleanup_pages;
            }

            ret = get_user_pages_fast(start & PAGE_MASK, nr_pages,
                                     FOLL_WRITE, pages[i]);
            if (ret < nr_pages) {
                if (ret > 0) {
                    for (j = 0; j < ret; j++) {
                        put_page(pages[i][j]);
                    }
                }
                kfree(pages[i]);
                pages[i] = NULL;
                ret = -EFAULT;
                goto cleanup_pages;
            }
            page_counts[i] = nr_pages;
        }
    }

    /* Build request */
    memset(&request, 0, sizeof(request));
    request.header.magic = WINAPI_MESSAGE_MAGIC;
    request.header.version = WINAPI_PROTOCOL_VERSION;
    request.header.message_type = WINAPI_MSG_REQUEST;
    request.header.api_id = WINAPI_API_PERF_TEST;
    request.header.request_id = atomic_inc_return(&dev->next_request_id);
    request.header.buffer_count = arg.buffer_count;
    request.header.inline_size = sizeof(winapi_perf_test_request_t);
    request.header.timestamp = ktime_get_ns();

    perf_req = (winapi_perf_test_request_t *)request.inline_data;
    perf_req->test_type = arg.test_type;
    perf_req->iterations = arg.iterations;
    perf_req->target_bytes = arg.target_bytes;

    /* Set up buffer descriptors */
    for (i = 0; i < arg.buffer_count; i++) {
        request.buffers[i].guest_pa = page_to_pfn(pages[i][0]) << PAGE_SHIFT;
        request.buffers[i].size = arg.buffer_sizes[i];
        request.buffers[i].flags = WINAPI_BUFFER_READ;
    }

    /* Send request and get response */
    ret = winapi_send_message_sync(dev, &request, &response);
    if (ret) {
        goto cleanup_pages;
    }

    /* Copy response back to user */
    if (response.header.error_code == WINAPI_OK) {
        perf_resp = (winapi_perf_test_response_t *)response.inline_data;
        arg.min_latency_ns = perf_resp->min_latency_ns;
        arg.max_latency_ns = perf_resp->max_latency_ns;
        arg.avg_latency_ns = perf_resp->avg_latency_ns;
        arg.throughput_mbps = perf_resp->throughput_mbps;
        arg.iterations_completed = perf_resp->iterations_completed;
        ret = 0;
    } else {
        ret = -EIO;
    }

    if (copy_to_user(user_arg, &arg, sizeof(arg))) {
        ret = -EFAULT;
    }

cleanup_pages:
    /* Unpin pages */
    for (i = 0; i < WINAPI_MAX_BUFFERS; i++) {
        if (pages[i]) {
            for (j = 0; j < page_counts[i]; j++) {
                put_page(pages[i][j]);
            }
            kfree(pages[i]);
        }
    }

    return ret;
}

/* IOCTL dispatcher */
static long winapi_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
    struct winapi_device *dev = file->private_data;

    if (!dev || !dev->channel) {
        return -ENODEV;
    }

    switch (cmd) {
    case WINAPI_IOC_ECHO:
        return winapi_ioctl_echo(dev, (struct winapi_ioctl_echo __user *)arg);

    case WINAPI_IOC_BUFFER_TEST:
        return winapi_ioctl_buffer_test(dev, (struct winapi_ioctl_buffer_test __user *)arg);

    case WINAPI_IOC_PERF_TEST:
        return winapi_ioctl_perf_test(dev, (struct winapi_ioctl_perf_test __user *)arg);

    default:
        return -ENOTTY;
    }
}

static const struct file_operations winapi_fops = {
    .owner = THIS_MODULE,
    .open = winapi_open,
    .release = winapi_release,
    .unlocked_ioctl = winapi_ioctl,
    .compat_ioctl = winapi_ioctl,
};

/* VMBus channel callback - process incoming messages */
static void winapi_channel_callback(void *context)
{
    struct winapi_device *dev = context;
    struct vmpacket_descriptor *desc;
    winapi_message_t *message;
    struct pending_request *pending;
    unsigned long flags;
    bool found = false;

    void *buffer;
    u32 buffer_len = 1024; /* Initial buffer size */
    u64 req_id;
    int ret;

    buffer = kmalloc(buffer_len, GFP_ATOMIC);
    if (!buffer) {
        pr_err("winapi: Failed to allocate receive buffer\n");
        return;
    }

    while ((ret = vmbus_recvpacket(dev->channel, buffer, buffer_len, &buffer_len, &req_id)) == 0 && buffer_len > 0) {
        if (buffer_len < sizeof(winapi_message_t)) {
            pr_err("winapi: Received packet too small\n");
            goto next_packet;
        }

        message = (winapi_message_t *)buffer;

        /* Validate message */
        if (message->header.magic != WINAPI_MESSAGE_MAGIC) {
            pr_err("winapi: Invalid message magic\n");
            goto next_packet;
        }

        /* Find pending request */
        spin_lock_irqsave(&dev->request_lock, flags);
        list_for_each_entry(pending, &dev->pending_requests, list) {
            if (pending->request_id == message->header.request_id) {
                memcpy(pending->response, message, sizeof(*message));
                pending->error = 0;
                complete(&pending->response_ready);
                found = true;
                break;
            }
        }
        spin_unlock_irqrestore(&dev->request_lock, flags);

        if (!found) {
            pr_warn("winapi: Received response for unknown request %llu\n",
                   message->header.request_id);
        }

next_packet:
        /* Reset buffer_len for next packet */
        buffer_len = 1024;
    }

    kfree(buffer);
}

/* VMBus probe function */
static int winapi_probe(struct hv_device *hv_dev, const struct hv_vmbus_device_id *dev_id)
{
    struct winapi_device *dev;
    int ret;

    pr_info("winapi: Probing device\n");

    /* Allocate device structure */
    dev = kzalloc(sizeof(*dev), GFP_KERNEL);
    if (!dev) {
        return -ENOMEM;
    }

    dev->hv_dev = hv_dev;
    spin_lock_init(&dev->request_lock);
    INIT_LIST_HEAD(&dev->pending_requests);
    init_waitqueue_head(&dev->response_queue);
    init_completion(&dev->channel_ready);
    atomic_set(&dev->next_request_id, 1);

    hv_set_drvdata(hv_dev, dev);
    g_winapi_dev = dev;

    /* Open VMBus channel */
    ret = vmbus_open(hv_dev->channel, 4096, 4096, NULL, 0,
                    winapi_channel_callback, dev);
    if (ret) {
        pr_err("winapi: Failed to open VMBus channel: %d\n", ret);
        goto error_free_dev;
    }

    dev->channel = hv_dev->channel;
    complete(&dev->channel_ready);

    /* Register character device */
    ret = alloc_chrdev_region(&dev->dev_number, 0, 1, DEVICE_NAME);
    if (ret) {
        pr_err("winapi: Failed to allocate device number: %d\n", ret);
        goto error_close_channel;
    }

    cdev_init(&dev->char_dev, &winapi_fops);
    ret = cdev_add(&dev->char_dev, dev->dev_number, 1);
    if (ret) {
        pr_err("winapi: Failed to add character device: %d\n", ret);
        goto error_unregister_chrdev;
    }

    /* Create device class */
    dev->dev_class = class_create(CLASS_NAME);
    if (IS_ERR(dev->dev_class)) {
        ret = PTR_ERR(dev->dev_class);
        pr_err("winapi: Failed to create device class: %d\n", ret);
        goto error_del_cdev;
    }

    /* Create device node */
    dev->device = device_create(dev->dev_class, &hv_dev->device,
                               dev->dev_number, NULL, DEVICE_NAME);
    if (IS_ERR(dev->device)) {
        ret = PTR_ERR(dev->device);
        pr_err("winapi: Failed to create device: %d\n", ret);
        goto error_destroy_class;
    }

    pr_info("winapi: Device registered successfully\n");
    return 0;

error_destroy_class:
    class_destroy(dev->dev_class);
error_del_cdev:
    cdev_del(&dev->char_dev);
error_unregister_chrdev:
    unregister_chrdev_region(dev->dev_number, 1);
error_close_channel:
    vmbus_close(hv_dev->channel);
error_free_dev:
    g_winapi_dev = NULL;
    kfree(dev);
    return ret;
}

/* VMBus remove function */
static void winapi_remove(struct hv_device *hv_dev)
{
    struct winapi_device *dev = hv_get_drvdata(hv_dev);

    pr_info("winapi: Removing device\n");

    if (dev) {
        /* Cleanup character device */
        device_destroy(dev->dev_class, dev->dev_number);
        class_destroy(dev->dev_class);
        cdev_del(&dev->char_dev);
        unregister_chrdev_region(dev->dev_number, 1);

        /* Close VMBus channel */
        vmbus_close(hv_dev->channel);

        g_winapi_dev = NULL;
        kfree(dev);
    }
}

/* Module initialization */
static int __init winapi_init(void)
{
    pr_info("winapi: Initializing Windows API Remoting client driver\n");
    return vmbus_driver_register(&winapi_vmbus_driver);
}

/* Module cleanup */
static void __exit winapi_exit(void)
{
    pr_info("winapi: Exiting Windows API Remoting client driver\n");
    vmbus_driver_unregister(&winapi_vmbus_driver);
}

module_init(winapi_init);
module_exit(winapi_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Windows API Remoting VMBus Client Driver");
MODULE_AUTHOR("WinAPI Remoting Team");
MODULE_VERSION("1.0");