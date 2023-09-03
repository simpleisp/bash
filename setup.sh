#!/bin/bash

# Install the application
sudo apt-get update
DEBIAN_FRONTEND=noninteractive sudo apt-get upgrade -y
chmod +x install.sh
sed -i -e 's/\r$//' install.sh
./install.sh < /dev/null
