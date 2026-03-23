#!/bin/bash
# OpenCode 本地构建和安装脚本

set -e

echo "🔨 开始构建 OpenCode..."

# 1. 构建单平台可执行文件（只构建当前平台）
bun run --cwd packages/opencode script/build.ts --single

# 2. 确定当前平台
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

if [[ "$OS" == "darwin" ]]; then
    OS="darwin"
fi

if [[ "$ARCH" == "arm64" ]] || [[ "$ARCH" == "aarch64" ]]; then
    ARCH="arm64"
elif [[ "$ARCH" == "x86_64" ]]; then
    ARCH="x64"
fi

BUILD_NAME="opencode-${OS}-${ARCH}"
BINARY_PATH="packages/opencode/dist/${BUILD_NAME}/bin/opencode"

if [[ ! -f "$BINARY_PATH" ]]; then
    echo "❌ 构建失败：找不到 $BINARY_PATH"
    exit 1
fi

echo "✅ 构建完成：$BINARY_PATH"

# 3. 安装到本地
echo ""
echo "📦 开始安装..."

INSTALL_DIR="$HOME/.opencode/bin"
mkdir -p "$INSTALL_DIR"

cp "$BINARY_PATH" "$INSTALL_DIR/opencode"
chmod +x "$INSTALL_DIR/opencode"

echo "✅ 已安装到：$INSTALL_DIR/opencode"

# 4. 添加到 PATH
echo ""
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo "⚠️  需要将 $INSTALL_DIR 添加到 PATH"
    echo ""
    echo "请运行以下命令（根据你的 shell）："
    echo ""
    
    if [[ "$SHELL" == *"zsh"* ]]; then
        echo "  echo 'export PATH=\"$INSTALL_DIR:\$PATH\"' >> ~/.zshrc"
        echo "  source ~/.zshrc"
    elif [[ "$SHELL" == *"bash"* ]]; then
        echo "  echo 'export PATH=\"$INSTALL_DIR:\$PATH\"' >> ~/.bashrc"
        echo "  source ~/.bashrc"
    else
        echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
    fi
    echo ""
else
    echo "✅ PATH 已配置"
fi

# 5. 验证安装
echo ""
if command -v opencode &> /dev/null; then
    VERSION=$(opencode --version 2>/dev/null || echo "unknown")
    echo "🎉 安装成功！"
    echo "   版本：$VERSION"
    echo ""
    echo "现在可以运行："
    echo "  opencode"
else
    echo "⚠️  安装完成，但 opencode 命令不在 PATH 中"
    echo "   请重新加载 shell 配置或手动添加到 PATH"
fi
