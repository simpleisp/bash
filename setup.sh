#!/bin/bash

# Install the application
sudo apt-get update
sudo apt-get upgrade -y
cd bash
chmod +x install.sh
sed -i -e 's/\r$//' install.sh
./install.sh
