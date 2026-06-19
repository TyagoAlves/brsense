#!/bin/sh
echo "Aplicando configuracao do firewall..."
pfctl -f /etc/pf.conf
pfctl -e
pfctl -sr
