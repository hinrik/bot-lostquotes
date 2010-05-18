#!/bin/bash

src=./transcripts
live=/var/www/nix.is/quotes
htmlize=./htmlize.py

ls $src/* > list
$htmlize
mv $src/*.html $live/
cd $live
rename 's/(\dx\d+).*/$1.html/' *
