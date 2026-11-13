10 rem lissajous curves in 64x32
20 rem pixel colour graphics
30 rem any key: next curve
40 for i=1 to 16:print:next
50 v=24576:dim q(3)
60 for i=0 to 3:read q(i):next
70 data 8,4,2,1
100 read a,b,p,c:if a=0 then end
110 for i=0 to 511:poke v+i,128:next
120 c=128+16*c
130 for t=0 to 6.29 step .02
140 x=int(31.5+31.4*sin(a*t))
150 y=int(15.5+15.4*sin(b*t+p))
160 gosub 500:next
170 get k$:if k$="" then 170
180 goto 100
500 rem plot pixel x,y in colour c
510 m=v+int(y/2)*32+int(x/2)
520 z=q((x and 1)+2*(y and 1))
530 poke m,(peek(m) and 15) or z or c
540 return
600 rem a,b: frequencies, p: phase,
610 rem c: colour (0-7)
620 data 1,1,.8,0,1,2,0,1,3,2,.5,5
630 data 3,4,0,6,2,3,.3,7,0,0,0,0
