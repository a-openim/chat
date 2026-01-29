#!/bin/bash

if ! command -v go &> /dev/null; then
    echo "Go is not installed. Please install Go first."
    exit 1
fi

TARGET_DIR="$HOME/.local/bin"
mkdir -p "$TARGET_DIR"

# Check if TARGET_DIR is in PATH
if [[ ":$PATH:" != *":$TARGET_DIR:"* ]]; then
    echo "Adding $TARGET_DIR to PATH in ~/.zshrc"
    echo "export PATH=\"$TARGET_DIR:\$PATH\"" >> ~/.zshrc
    export PATH="$TARGET_DIR:$PATH"
fi

if ! command -v mage &> /dev/null; then
    echo "Installing Mage to $TARGET_DIR ..."
    GOBIN=$TARGET_DIR go install github.com/magefile/mage@latest
fi

if ! command -v mage &> /dev/null; then
    echo "Mage installation failed."
    echo "Please ensure that $TARGET_DIR is in your \$PATH."
    exit 1
fi

echo "Mage installed successfully."

go mod download -x

say -v Meijia "congratulations"