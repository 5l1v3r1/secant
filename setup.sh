#!/usr/bin/env bash

# Load a configuration from secant.conf
source secant.conf

# Install Lynis
# https://github.com/CISOfy/lynis.git
mkdir -p /usr/local/lynis
wget -P ${lynis_directory} https://cisofy.com/files/lynis-${lynis_version}.tar.gz
tar xfvz ${lynis_directory}/lynis-${lynis_version}.tar.gz -C ${lynis_directory}
rm ${lynis_directory}/lynis-${lynis_version}.tar.gz

# Edit lynis profil, exclude tests that works with dpkg
sed -i -e "s@# config:test_skip_always:AAAA-1234 BBBB-5678 CCCC-9012:@config:test_skip_always:PKGS-7345 PKGS-7328 PKGS-7330 PKGS-7314PKGS-7312 PKGS-7310 PKGS-7308 PKGS-7306 PKGS-7304 PKGS-7302 PKGS-7302 PKGS-7301 PKGS-7392:@" ${lynis_directory}/lynis/default.prf
# Install Nmap
sudo apt-get install nmap -y

# Install xmlscarlet
sudo apt-get install xmlstarlet -y
