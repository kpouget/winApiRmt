#!/bin/bash
# Download Windows Development Tools
# Downloads Visual Studio Community and Windows Driver Kit (WDK) for driver development

set -e

echo "🔧 Windows Development Tools Downloader"
echo "======================================="
echo ""

# Create downloads directory
DOWNLOAD_DIR="$(pwd)"
echo "📂 Download directory: $DOWNLOAD_DIR"
echo ""

# Check for required tools
if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
    echo "❌ Error: Neither wget nor curl is installed"
    echo "   Please install wget or curl to download files"
    exit 1
fi

# Function to download with progress
download_file() {
    local url="$1"
    local filename="$2"
    local description="$3"

    echo "📥 Downloading $description..."
    echo "   URL: $url"
    echo "   File: $filename"

    if [ -f "$filename" ]; then
        echo "   ✅ File already exists, skipping download"
        echo "      Size: $(ls -lh "$filename" | awk '{print $5}')"
        return 0
    fi

    if command -v wget >/dev/null 2>&1; then
        wget --progress=bar --show-progress -O "$filename" "$url"
    else
        curl -L --progress-bar -o "$filename" "$url"
    fi

    if [ $? -eq 0 ] && [ -f "$filename" ]; then
        echo "   ✅ Download completed successfully"
        echo "      Size: $(ls -lh "$filename" | awk '{print $5}')"
    else
        echo "   ❌ Download failed"
        rm -f "$filename"
        return 1
    fi
    echo ""
}

# Download Visual Studio Community 2022
echo "1️⃣  Visual Studio Community 2022"
echo "-----------------------------------"
VS_URL="https://download.visualstudio.microsoft.com/download/pr/3105fcfe-e771-41d6-9a1c-fc971e7d03a7/8eb13958dc429a6e6f7e0d6704d43a55f18d02a253608351b6bf6723ffdaf24e/vs_Community.exe"
VS_FILE="vs_Community.exe"
download_file "$VS_URL" "$VS_FILE" "Visual Studio Community 2022"

# Download Windows Driver Kit (WDK)
echo "2️⃣  Windows Driver Kit (WDK)"
echo "------------------------------"
WDK_URL="https://go.microsoft.com/fwlink/?linkid=2196230"
WDK_FILE="wdksetup.exe"
download_file "$WDK_URL" "$WDK_FILE" "Windows Driver Kit (WDK)"

# Download Windows SDK (if needed)
echo "3️⃣  Windows SDK (Latest)"
echo "-------------------------"
SDK_URL="https://go.microsoft.com/fwlink/p/?linkid=2196241"
SDK_FILE="winsdksetup.exe"
download_file "$SDK_URL" "$SDK_FILE" "Windows SDK (Latest)"

echo "✨ Download Summary"
echo "=================="
echo ""

if [ -f "$VS_FILE" ]; then
    echo "✅ Visual Studio Community: $VS_FILE ($(ls -lh "$VS_FILE" | awk '{print $5}'))"
else
    echo "❌ Visual Studio Community: Download failed"
fi

if [ -f "$WDK_FILE" ]; then
    echo "✅ Windows Driver Kit: $WDK_FILE ($(ls -lh "$WDK_FILE" | awk '{print $5}'))"
else
    echo "❌ Windows Driver Kit: Download failed"
fi

if [ -f "$SDK_FILE" ]; then
    echo "✅ Windows SDK: $SDK_FILE ($(ls -lh "$SDK_FILE" | awk '{print $5}'))"
else
    echo "❌ Windows SDK: Download failed"
fi

echo ""
echo "📋 Next Steps:"
echo "1. Transfer these files to your Windows machine"
echo "2. Run vs_Community.exe and install:"
echo "   • Desktop development with C++"
echo "   • Windows 10/11 SDK"
echo "   • MSVC compiler toolset"
echo "3. Run wdksetup.exe to install Windows Driver Kit"
echo "4. Run winsdksetup.exe if you need additional SDK components"
echo ""
echo "💡 For automated installation, see install_on_windows.cmd"
echo ""
echo "🎯 Once installed, you can build the driver using:"
echo "   ./build.sh                    (from project root)"
echo "   build_driver_manual.cmd       (from driver directory)"