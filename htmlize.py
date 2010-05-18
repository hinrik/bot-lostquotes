#!/usr/bin/python
import os,sys,string

filelist = open("list","r")
filelines = filelist.readlines()

for INFILE in filelines:
    title, suffix = string.split(INFILE.rstrip(),".txt")
    print "Processing '%s'" % title

    OUTFILE=INFILE.rstrip()+".html"

    fin = open(INFILE.rstrip(),"r")
    fout = open(OUTFILE,"w")

    fout.write("<html>\n<head>\n<title>%s</title>\n</head><meta http-equiv='Content-Type' context='text/html; charset=utf-8'/>\n<body>" % title) 
    fout.write("<div style='font-size: 20pt; font-weight:bold'>%s</div><br/><br/><br/>" % title)

    count = 1
    content = fin.readlines()

    fout.write("<table>")

    for line in content:
        if line == "\n":
            fout.write("<tr><td><br/></td><td><br/></td></tr>")
        else:
            fout.write("<tr valign='top'><td valign='top' style='text-align: right; background-color: #c0c0c0; color: #404040'><pre>%d</pre></td><td valign='top' style='padding-left: 0.5em'><span id='L%d' rel='#L%d'>%s</span></td></tr>" % (count,count,count,line))
            count = count + 1
    fout.write("</table></body></html>")
    fin.close()
    fout.close()

