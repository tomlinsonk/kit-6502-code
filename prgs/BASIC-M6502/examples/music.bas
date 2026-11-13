10 rem play a tune on the sid
20 rem and draw a piano roll
30 s=32256:v=24576:n$="C D EF G A B"
40 for i=0 to 24:poke s+i,0:next
50 poke s+24,15:poke s+3,8
60 poke s+5,9:poke s+6,0
70 t=800:rem delay loops per beat
100 read a$,d:if d=0 then 300
110 l$=left$(a$,1):o=val(right$(a$,1))
120 for i=1 to 12
130 if mid$(n$,i,1)=l$ then m=i-1
140 next
150 if mid$(a$,2,1)="#" then m=m+1
160 f=440*2^((m+12*o-57)/12)
170 r=int(f*9.1022+.5)
180 poke s,r and 255:poke s+1,r/256
190 poke s+4,65:print:print a$;
200 x=v+484+2*m
210 for i=0 to 2*d-1
220 poke x+i,143+16*(m and 7):next
230 for i=1 to t*d:next
240 poke s+4,64
250 goto 100
300 poke s+24,0:print
310 rem ode to joy, beethoven
320 rem note, beats; end with x,0
400 data e4,1,e4,1,f4,1,g4,1
410 data g4,1,f4,1,e4,1,d4,1
420 data c4,1,c4,1,d4,1,e4,1
430 data e4,1.5,d4,.5,d4,2
440 data e4,1,e4,1,f4,1,g4,1
450 data g4,1,f4,1,e4,1,d4,1
460 data c4,1,c4,1,d4,1,e4,1
470 data d4,1.5,c4,.5,c4,2,x,0
