#!/usr/bin/env bash
set -euf -o pipefail

# Dependencies script for ort-builder
# Installs LLVM/Clang 20, libc++, UPX, and proto toolchain manager

# Versions
LLVM_VERSION="20"
UPX_VERSION="5.0.2"

echo "=== Installing ort-builder dependencies ==="

# Detect OS
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  OS=$ID
  OS_VERSION=$VERSION_ID
else
  echo "ERROR: Cannot detect OS"
  exit 1
fi

echo "Detected OS: $OS $OS_VERSION"

# Install proto (moonrepo toolchain manager)
install_proto() {
  if command -v proto &>/dev/null; then
    echo "proto already installed: $(proto --version)"
  else
    echo "Installing proto..."
    curl -fsSL https://moonrepo.dev/install/proto.sh | bash
    export PATH="$HOME/.proto/bin:$PATH"
    echo "proto installed: $(proto --version)"
  fi
}

# Install LLVM/Clang and libc++
install_llvm() {
  if command -v "clang-${LLVM_VERSION}" &>/dev/null; then
    echo "clang-${LLVM_VERSION} already installed: $(clang-${LLVM_VERSION} --version | head -1)"
  else
    echo "Installing LLVM ${LLVM_VERSION}..."

    case $OS in
    ubuntu | debian)
      # Add LLVM apt repository
      wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | sudo tee /etc/apt/trusted.gpg.d/apt.llvm.org.asc

      # Determine codename
      if [[ "$OS" == "ubuntu" ]]; then
        CODENAME=$(lsb_release -cs)
      else
        CODENAME=$(lsb_release -cs)
      fi

      echo "deb http://apt.llvm.org/$CODENAME/ llvm-toolchain-$CODENAME-${LLVM_VERSION} main" | sudo tee /etc/apt/sources.list.d/llvm-${LLVM_VERSION}.list
      sudo apt update
      sudo apt install -y "clang-${LLVM_VERSION}" "llvm-${LLVM_VERSION}" "lld-${LLVM_VERSION}"
      ;;
    *)
      echo "ERROR: Unsupported OS for LLVM installation: $OS"
      echo "Please install LLVM ${LLVM_VERSION} manually from https://apt.llvm.org"
      exit 1
      ;;
    esac
  fi
}

# Install libc++ for Clang
install_libcxx() {
  if dpkg -l | grep -q "libc++-${LLVM_VERSION}-dev"; then
    echo "libc++-${LLVM_VERSION}-dev already installed"
  else
    echo "Installing libc++ ${LLVM_VERSION}..."
    sudo apt install -y "libc++-${LLVM_VERSION}-dev" "libc++abi-${LLVM_VERSION}-dev"
  fi
}

# Install Python build dependencies
install_python_deps() {
  if [[ -d "venv" ]]; then
    echo "Python venv already exists"
  else
    echo "Creating Python venv..."
    python3 -m venv venv
  fi

  echo "Installing Python dependencies..."
  source venv/bin/activate
  pip install --upgrade pip
  pip install numpy packaging
}

# Install system build tools
install_build_tools() {
  echo "Installing build tools..."
  sudo apt install -y build-essential ninja-build git wget curl
}

# Install UPX for binary compression (Linux only)
install_upx() {
  if command -v upx &>/dev/null; then
    echo "upx already installed: $(upx --version | head -1)"
  elif [[ -f "$HOME/bin/upx" ]]; then
    echo "upx already installed: $($HOME/bin/upx --version | head -1)"
  else
    echo "Installing UPX ${UPX_VERSION}..."
    mkdir -p "$HOME/bin"
    cd /tmp
    curl -L -o upx.tar.xz "https://github.com/upx/upx/releases/download/v${UPX_VERSION}/upx-${UPX_VERSION}-amd64_linux.tar.xz"
    tar -xf upx.tar.xz
    mv "upx-${UPX_VERSION}-amd64_linux/upx" "$HOME/bin/"
    rm -rf upx.tar.xz "upx-${UPX_VERSION}-amd64_linux"
    echo "upx installed: $($HOME/bin/upx --version | head -1)"
    echo "Add to PATH: export PATH=\"\$HOME/bin:\$PATH\""
  fi
}

# Main installation
main() {
  echo ""
  echo "Step 1/6: Installing proto toolchain manager..."
  install_proto

  echo ""
  echo "Step 2/6: Installing build tools..."
  install_build_tools

  echo ""
  echo "Step 3/6: Installing LLVM/Clang ${LLVM_VERSION}..."
  install_llvm

  echo ""
  echo "Step 4/6: Installing libc++..."
  install_libcxx

  echo ""
  echo "Step 5/6: Setting up Python environment..."
  install_python_deps

  echo ""
  echo "Step 6/6: Installing UPX..."
  install_upx

  echo ""
  echo "=== Dependencies installed successfully ==="
  echo ""
  echo "Next steps:"
  echo "  1. Add to PATH: export PATH=\"\$HOME/.proto/bin:\$HOME/bin:\$PATH\""
  echo "  2. Activate venv: source venv/bin/activate"
  echo "  3. Run build: ./build-linux-static.sh model.required_operators_and_types.config"
  echo "  4. Compress binary: upx --best --lzma <binary>"
  echo ""
}

# Allow running individual functions
case "${1:-all}" in
proto)
  install_proto
  ;;
llvm)
  install_llvm
  ;;
libcxx)
  install_libcxx
  ;;
python)
  install_python_deps
  ;;
tools)
  install_build_tools
  ;;
upx)
  install_upx
  ;;
all)
  main
  ;;
*)
  echo "Usage: $0 [all|proto|llvm|libcxx|python|tools|upx]"
  exit 1
  ;;
esac
