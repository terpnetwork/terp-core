#!/bin/sh
# copy current home directory to new location
cp -r "$HOME"/.terp "$HOME"/.terpd
# check if home directory has been updated 
terpd genesis validate-genesis
# remove old home directory
rm -rf "$HOME"/.terp
