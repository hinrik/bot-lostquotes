#!/bin/bash

live=/var/www/nix.is/quotes

cd transcripts
ls * > list
../htmlize.py
mv *.html $live/
rm list
cd $live
rename 's/(\dx\d+).*/$1.html/' *
