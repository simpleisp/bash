#!/bin/bash

# Install the application
sudo apt-get update
sudo apt-get upgrade -y
git clone https://github.com/simpleisp/bash.git
cd bash
chmod +x install.sh
sed -i -e 's/\r$//' install.sh
./install.sh
