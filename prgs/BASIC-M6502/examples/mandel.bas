10 rem mandelbrot set in colour
20 rem esc stops, any key ends
30 for i=1 to 16:print:next
40 v=24576:m=24
100 for y=0 to 7
110 ci=(7.5-y)*.14
120 for x=0 to 31
130 cr=x*.094-2.2
140 zr=0:zi=0:n=0
150 t=zr*zr-zi*zi+cr:zi=2*zr*zi+ci
160 zr=t:n=n+1
170 if n<m and zr*zr+zi*zi<4 then 150
180 k=128:if n>1 and n<m then k=143+16*(n and 7)
190 poke v+y*32+x,k:poke v+(15-y)*32+x,k
200 next x,y
210 get k$:if k$="" then 210
