#|
The MIT License

Copyright (c) 2017-2018 Refined Audiometrics Laboratory, LLC

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
|#

(defun rnd (n nd)
  (* nd (round n nd)))

(let* ((fsamp 32000)
       (nfft  512)
       (nfft/2 (truncate nfft 2))
       (hz/cell (float (/ fsamp nfft)))
       (fs    (progn
                (format t "~%Cell   FkHz   ZBark        Cells~&")
                (format t "-------------------------------------~&")
                (loop for ix from 0 below nfft/2 collect
                    (let* ((fkhz (* ix 1/1000 hz/cell))
                           (z    (cbr fkhz))
                           (f<   (inverse-cbr (- z 0.5)))
                           (f>   (inverse-cbr (+ z 0.5)))
                           (n<   (/ f< 1/1000 hz/cell))
                           (n>   (min (1- nfft/2) (/ f> 1/1000 hz/cell))))
                      (format t "~3D   ~5,2F   ~5,2F   (~6,2F ~6,2F) [~3D ~3D] (~D)~&"
                              ix fkhz z n< n> (round n<) (round n>) (1+ (- (round n>) (round n<))))
                      (list :cell  ix
                            :fkhz  fkhz
                            :zbark z
                            :cells (list n< n>)))
                    ))))
  (inspect fs))

(loop for db from 0 to 80 by 10 do
      (format t "~D  ~,2F~&" db (+ (- db 100) 5.2 (* 0.2 (- 100 db)))))

(let ((hlev    64) ;; for 64 dB elev @ 4 kHz
      (sigdbfs 0))
  ;; for hc rate of 3.575 dB/Bark
  ;; dbcorr(h,h) = 9 dB
  ;; cmpr ratio 4.5
  ;; compute needed atten at 100 dBSPL = 0 dBFS
  (mapcar (lambda (fkhz)
            (let* ((dh (* 3.575
                          (- (bark-ctr fkhz)
                             (bark-ctr 4))))
                   (gain100 (- 9 (* (- 1 (/ 4.5)) (- (+ 100 sigdbfs) (+ hlev dh))))))
              (list fkhz gain100)))
          '(0.25 0.5 1 2 4 8 16)))
#|
NFFT: 512
FSAMP: 32000

Cell   FkHz   ZBark        Cells
-------------------------------------
  0    0.00    0.00   (  0.04   1.25) [  0   1] (2)
  1    0.06    0.30   (  0.39   1.63) [  0   2] (3)
  2    0.12    1.08   (  1.35   2.68) [  1   3] (3)
  3    0.19    1.81   (  2.31   3.72) [  2   4] (3)
  4    0.25    2.50   (  3.27   4.76) [  3   5] (3)
  5    0.31    3.16   (  4.23   5.80) [  4   6] (3)
  6    0.38    3.78   (  5.19   6.85) [  5   7] (3)
  7    0.44    4.36   (  6.14   7.90) [  6   8] (3)
  8    0.50    4.92   (  7.10   8.94) [  7   9] (3)
  9    0.56    5.45   (  8.05   9.99) [  8  10] (3)
 10    0.62    5.95   (  9.01  11.04) [  9  11] (3)
 11    0.69    6.43   (  9.96  12.09) [ 10  12] (3)
 12    0.75    6.89   ( 10.91  13.15) [ 11  13] (3)
 13    0.81    7.33   ( 11.86  14.20) [ 12  14] (3)
 14    0.88    7.74   ( 12.81  15.26) [ 13  15] (3)
 15    0.94    8.14   ( 13.76  16.31) [ 14  16] (3)
 16    1.00    8.53   ( 14.70  17.37) [ 15  17] (3)
 17    1.06    8.89   ( 15.65  18.43) [ 16  18] (3)
 18    1.12    9.25   ( 16.59  19.49) [ 17  19] (3)
 19    1.19    9.58   ( 17.54  20.55) [ 18  21] (4)
 20    1.25    9.91   ( 18.48  21.62) [ 18  22] (5)
 21    1.31   10.22   ( 19.42  22.68) [ 19  23] (5)
 22    1.38   10.52   ( 20.36  23.75) [ 20  24] (5)
 23    1.44   10.81   ( 21.30  24.82) [ 21  25] (5)
 24    1.50   11.09   ( 22.24  25.88) [ 22  26] (5)
 25    1.56   11.36   ( 23.17  26.95) [ 23  27] (5)
 26    1.62   11.62   ( 24.11  28.03) [ 24  28] (5)
 27    1.69   11.87   ( 25.04  29.10) [ 25  29] (5)
 28    1.75   12.12   ( 25.98  30.17) [ 26  30] (5)
 29    1.81   12.35   ( 26.91  31.25) [ 27  31] (5)
 30    1.88   12.58   ( 27.84  32.32) [ 28  32] (5)
 31    1.94   12.80   ( 28.77  33.40) [ 29  33] (5)
 32    2.00   13.01   ( 29.70  34.48) [ 30  34] (5)
 33    2.06   13.22   ( 30.63  35.56) [ 31  36] (6)
 34    2.12   13.42   ( 31.55  36.64) [ 32  37] (6)
 35    2.19   13.61   ( 32.48  37.73) [ 32  38] (7)
 36    2.25   13.80   ( 33.41  38.81) [ 33  39] (7)
 37    2.31   13.98   ( 34.33  39.90) [ 34  40] (7)
 38    2.38   14.16   ( 35.25  40.98) [ 35  41] (7)
 39    2.44   14.33   ( 36.17  42.07) [ 36  42] (7)
 40    2.50   14.50   ( 37.09  43.16) [ 37  43] (7)
 41    2.56   14.66   ( 38.01  44.25) [ 38  44] (7)
 42    2.62   14.82   ( 38.93  45.35) [ 39  45] (7)
 43    2.69   14.97   ( 39.85  46.44) [ 40  46] (7)
 44    2.75   15.12   ( 40.77  47.54) [ 41  48] (8)
 45    2.81   15.27   ( 41.68  48.63) [ 42  49] (8)
 46    2.88   15.41   ( 42.60  49.73) [ 43  50] (8)
 47    2.94   15.55   ( 43.51  50.83) [ 44  51] (8)
 48    3.00   15.69   ( 44.42  51.93) [ 44  52] (9)
 49    3.06   15.82   ( 45.33  53.03) [ 45  53] (9)
 50    3.12   15.95   ( 46.25  54.14) [ 46  54] (9)
 51    3.19   16.07   ( 47.15  55.24) [ 47  55] (9)
 52    3.25   16.19   ( 48.06  56.35) [ 48  56] (9)
 53    3.31   16.31   ( 48.97  57.46) [ 49  57] (9)
 54    3.38   16.43   ( 49.88  58.56) [ 50  59] (10)
 55    3.44   16.54   ( 50.78  59.68) [ 51  60] (10)
 56    3.50   16.66   ( 51.69  60.79) [ 52  61] (10)
 57    3.56   16.76   ( 52.59  61.90) [ 53  62] (10)
 58    3.62   16.87   ( 53.49  63.02) [ 53  63] (11)
 59    3.69   16.98   ( 54.39  64.13) [ 54  64] (11)
 60    3.75   17.08   ( 55.29  65.25) [ 55  65] (11)
 61    3.81   17.18   ( 56.19  66.37) [ 56  66] (11)
 62    3.88   17.27   ( 57.09  67.49) [ 57  67] (11)
 63    3.94   17.37   ( 57.99  68.61) [ 58  69] (12)
 64    4.00   17.46   ( 58.88  69.73) [ 59  70] (12)
 65    4.06   17.55   ( 59.78  70.86) [ 60  71] (12)
 66    4.12   17.64   ( 60.67  71.98) [ 61  72] (12)
 67    4.19   17.73   ( 61.56  73.11) [ 62  73] (12)
 68    4.25   17.82   ( 62.46  74.24) [ 62  74] (13)
 69    4.31   17.90   ( 63.35  75.37) [ 63  75] (13)
 70    4.38   17.99   ( 64.24  76.50) [ 64  77] (14)
 71    4.44   18.07   ( 65.13  77.63) [ 65  78] (14)
 72    4.50   18.15   ( 66.01  78.77) [ 66  79] (14)
 73    4.56   18.22   ( 66.90  79.91) [ 67  80] (14)
 74    4.62   18.30   ( 67.79  81.04) [ 68  81] (14)
 75    4.69   18.38   ( 68.67  82.18) [ 69  82] (14)
 76    4.75   18.45   ( 69.56  83.32) [ 70  83] (14)
 77    4.81   18.52   ( 70.44  84.46) [ 70  84] (15)
 78    4.88   18.59   ( 71.32  85.61) [ 71  86] (16)
 79    4.94   18.66   ( 72.20  86.75) [ 72  87] (16)
 80    5.00   18.73   ( 73.08  87.90) [ 73  88] (16)
 81    5.06   18.80   ( 73.96  89.05) [ 74  89] (16)
 82    5.12   18.86   ( 74.84  90.19) [ 75  90] (16)
 83    5.19   18.93   ( 75.72  91.35) [ 76  91] (16)
 84    5.25   18.99   ( 76.59  92.50) [ 77  92] (16)
 85    5.31   19.05   ( 77.47  93.65) [ 77  94] (18)
 86    5.38   19.12   ( 78.34  94.81) [ 78  95] (18)
 87    5.44   19.18   ( 79.22  95.96) [ 79  96] (18)
 88    5.50   19.24   ( 80.09  97.12) [ 80  97] (18)
 89    5.56   19.29   ( 80.96  98.28) [ 81  98] (18)
 90    5.62   19.35   ( 81.83  99.44) [ 82  99] (18)
 91    5.69   19.41   ( 82.70 100.60) [ 83 101] (19)
 92    5.75   19.46   ( 83.57 101.77) [ 84 102] (19)
 93    5.81   19.52   ( 84.44 102.93) [ 84 103] (20)
 94    5.88   19.57   ( 85.30 104.10) [ 85 104] (20)
 95    5.94   19.63   ( 86.17 105.27) [ 86 105] (20)
 96    6.00   19.68   ( 87.03 106.44) [ 87 106] (20)
 97    6.06   19.73   ( 87.90 107.61) [ 88 108] (21)
 98    6.12   19.78   ( 88.76 108.78) [ 89 109] (21)
 99    6.19   19.83   ( 89.62 109.96) [ 90 110] (21)
100    6.25   19.88   ( 90.48 111.13) [ 90 111] (22)
101    6.31   19.93   ( 91.34 112.31) [ 91 112] (22)
102    6.38   19.98   ( 92.20 113.49) [ 92 113] (22)
103    6.44   20.02   ( 93.06 114.67) [ 93 115] (23)
104    6.50   20.07   ( 93.92 115.85) [ 94 116] (23)
105    6.56   20.11   ( 94.77 117.03) [ 95 117] (23)
106    6.62   20.16   ( 95.63 118.22) [ 96 118] (23)
107    6.69   20.20   ( 96.48 119.41) [ 96 119] (24)
108    6.75   20.25   ( 97.33 120.59) [ 97 121] (25)
109    6.81   20.29   ( 98.19 121.78) [ 98 122] (25)
110    6.88   20.33   ( 99.04 122.97) [ 99 123] (25)
111    6.94   20.37   ( 99.89 124.17) [100 124] (25)
112    7.00   20.42   (100.74 125.36) [101 125] (25)
113    7.06   20.46   (101.59 126.56) [102 127] (26)
114    7.12   20.50   (102.43 127.75) [102 128] (27)
115    7.19   20.54   (103.28 128.95) [103 129] (27)
116    7.25   20.57   (104.13 130.15) [104 130] (27)
117    7.31   20.61   (104.97 131.36) [105 131] (27)
118    7.38   20.65   (105.82 132.56) [106 133] (28)
119    7.44   20.69   (106.66 133.77) [107 134] (28)
120    7.50   20.73   (107.50 134.97) [108 135] (28)
121    7.56   20.76   (108.34 136.18) [108 136] (29)
122    7.62   20.80   (109.18 137.39) [109 137] (29)
123    7.69   20.83   (110.02 138.60) [110 139] (30)
124    7.75   20.87   (110.86 139.82) [111 140] (30)
125    7.81   20.90   (111.70 141.03) [112 141] (30)
126    7.88   20.94   (112.53 142.25) [113 142] (30)
127    7.94   20.97   (113.37 143.46) [113 143] (31)
128    8.00   21.00   (114.20 144.68) [114 145] (32)
129    8.06   21.04   (115.04 145.91) [115 146] (32)
130    8.12   21.07   (115.87 147.13) [116 147] (32)
131    8.19   21.10   (116.70 148.35) [117 148] (32)
132    8.25   21.13   (117.53 149.58) [118 150] (33)
133    8.31   21.16   (118.37 150.81) [118 151] (34)
134    8.38   21.20   (119.19 152.03) [119 152] (34)
135    8.44   21.23   (120.02 153.27) [120 153] (34)
136    8.50   21.26   (120.85 154.50) [121 154] (34)
137    8.56   21.29   (121.68 155.73) [122 156] (35)
138    8.62   21.32   (122.50 156.97) [123 157] (35)
139    8.69   21.34   (123.33 158.21) [123 158] (36)
140    8.75   21.37   (124.15 159.44) [124 159] (36)
141    8.81   21.40   (124.98 160.69) [125 161] (37)
142    8.88   21.43   (125.80 161.93) [126 162] (37)
143    8.94   21.46   (126.62 163.17) [127 163] (37)
144    9.00   21.49   (127.44 164.42) [127 164] (38)
145    9.06   21.51   (128.26 165.66) [128 166] (39)
146    9.12   21.54   (129.08 166.91) [129 167] (39)
147    9.19   21.57   (129.90 168.16) [130 168] (39)
148    9.25   21.59   (130.71 169.42) [131 169] (39)
149    9.31   21.62   (131.53 170.67) [132 171] (40)
150    9.38   21.64   (132.34 171.93) [132 172] (41)
151    9.44   21.67   (133.16 173.18) [133 173] (41)
152    9.50   21.69   (133.97 174.44) [134 174] (41)
153    9.56   21.72   (134.78 175.70) [135 176] (42)
154    9.62   21.74   (135.60 176.96) [136 177] (42)
155    9.69   21.77   (136.41 178.23) [136 178] (43)
156    9.75   21.79   (137.22 179.49) [137 179] (43)
157    9.81   21.82   (138.03 180.76) [138 181] (44)
158    9.88   21.84   (138.83 182.03) [139 182] (44)
159    9.94   21.86   (139.64 183.30) [140 183] (44)
160   10.00   21.89   (140.45 184.57) [140 185] (46)
161   10.06   21.91   (141.25 185.85) [141 186] (46)
162   10.12   21.93   (142.06 187.12) [142 187] (46)
163   10.19   21.95   (142.86 188.40) [143 188] (46)
164   10.25   21.98   (143.67 189.68) [144 190] (47)
165   10.31   22.00   (144.47 190.96) [144 191] (48)
166   10.38   22.02   (145.27 192.24) [145 192] (48)
167   10.44   22.04   (146.07 193.53) [146 194] (49)
168   10.50   22.06   (146.87 194.82) [147 195] (49)
169   10.56   22.08   (147.67 196.10) [148 196] (49)
170   10.62   22.10   (148.47 197.39) [148 197] (50)
171   10.69   22.13   (149.26 198.68) [149 199] (51)
172   10.75   22.15   (150.06 199.98) [150 200] (51)
173   10.81   22.17   (150.85 201.27) [151 201] (51)
174   10.88   22.19   (151.65 202.57) [152 203] (52)
175   10.94   22.21   (152.44 203.87) [152 204] (53)
176   11.00   22.23   (153.24 205.17) [153 205] (53)
177   11.06   22.24   (154.03 206.47) [154 206] (53)
178   11.12   22.26   (154.82 207.77) [155 208] (54)
179   11.19   22.28   (155.61 209.08) [156 209] (54)
180   11.25   22.30   (156.40 210.39) [156 210] (55)
181   11.31   22.32   (157.19 211.70) [157 212] (56)
182   11.38   22.34   (157.98 213.01) [158 213] (56)
183   11.44   22.36   (158.76 214.32) [159 214] (56)
184   11.50   22.38   (159.55 215.63) [160 216] (57)
185   11.56   22.39   (160.33 216.95) [160 217] (58)
186   11.62   22.41   (161.12 218.27) [161 218] (58)
187   11.69   22.43   (161.90 219.59) [162 220] (59)
188   11.75   22.45   (162.69 220.91) [163 221] (59)
189   11.81   22.46   (163.47 222.23) [163 222] (60)
190   11.88   22.48   (164.25 223.56) [164 224] (61)
191   11.94   22.50   (165.03 224.89) [165 225] (61)
192   12.00   22.52   (165.81 226.21) [166 226] (61)
193   12.06   22.53   (166.59 227.54) [167 228] (62)
194   12.12   22.55   (167.37 228.88) [167 229] (63)
195   12.19   22.57   (168.14 230.21) [168 230] (63)
196   12.25   22.58   (168.92 231.55) [169 232] (64)
197   12.31   22.60   (169.70 232.89) [170 233] (64)
198   12.38   22.61   (170.47 234.23) [170 234] (65)
199   12.44   22.63   (171.24 235.57) [171 236] (66)
200   12.50   22.65   (172.02 236.91) [172 237] (66)
201   12.56   22.66   (172.79 238.26) [173 238] (66)
202   12.62   22.68   (173.56 239.60) [174 240] (67)
203   12.69   22.69   (174.33 240.95) [174 241] (68)
204   12.75   22.71   (175.10 242.30) [175 242] (68)
205   12.81   22.72   (175.87 243.66) [176 244] (69)
206   12.88   22.74   (176.64 245.01) [177 245] (69)
207   12.94   22.75   (177.41 246.37) [177 246] (70)
208   13.00   22.77   (178.17 247.73) [178 248] (71)
209   13.06   22.78   (178.94 249.09) [179 249] (71)
210   13.12   22.80   (179.70 250.45) [180 250] (71)
211   13.19   22.81   (180.47 251.81) [180 252] (73)
212   13.25   22.83   (181.23 253.18) [181 253] (73)
213   13.31   22.84   (182.00 254.55) [182 255] (74)
214   13.38   22.85   (182.76 255.00) [183 255] (73)
215   13.44   22.87   (183.52 255.00) [184 255] (72)
216   13.50   22.88   (184.28 255.00) [184 255] (72)
217   13.56   22.89   (185.04 255.00) [185 255] (71)
218   13.62   22.91   (185.80 255.00) [186 255] (70)
219   13.69   22.92   (186.55 255.00) [187 255] (69)
220   13.75   22.94   (187.31 255.00) [187 255] (69)
221   13.81   22.95   (188.07 255.00) [188 255] (68)
222   13.88   22.96   (188.82 255.00) [189 255] (67)
223   13.94   22.97   (189.58 255.00) [190 255] (66)
224   14.00   22.99   (190.33 255.00) [190 255] (66)
225   14.06   23.00   (191.09 255.00) [191 255] (65)
226   14.12   23.01   (191.84 255.00) [192 255] (64)
227   14.19   23.03   (192.59 255.00) [193 255] (63)
228   14.25   23.04   (193.34 255.00) [193 255] (63)
229   14.31   23.05   (194.09 255.00) [194 255] (62)
230   14.38   23.06   (194.84 255.00) [195 255] (61)
231   14.44   23.08   (195.59 255.00) [196 255] (60)
232   14.50   23.09   (196.34 255.00) [196 255] (60)
233   14.56   23.10   (197.09 255.00) [197 255] (59)
234   14.62   23.11   (197.83 255.00) [198 255] (58)
235   14.69   23.12   (198.58 255.00) [199 255] (57)
236   14.75   23.14   (199.32 255.00) [199 255] (57)
237   14.81   23.15   (200.07 255.00) [200 255] (56)
238   14.88   23.16   (200.81 255.00) [201 255] (55)
239   14.94   23.17   (201.55 255.00) [202 255] (54)
240   15.00   23.18   (202.29 255.00) [202 255] (54)
241   15.06   23.19   (203.03 255.00) [203 255] (53)
242   15.12   23.20   (203.77 255.00) [204 255] (52)
243   15.19   23.22   (204.51 255.00) [205 255] (51)
244   15.25   23.23   (205.25 255.00) [205 255] (51)
245   15.31   23.24   (205.99 255.00) [206 255] (50)
246   15.38   23.25   (206.73 255.00) [207 255] (49)
247   15.44   23.26   (207.46 255.00) [207 255] (49)
248   15.50   23.27   (208.20 255.00) [208 255] (48)
249   15.56   23.28   (208.94 255.00) [209 255] (47)
250   15.62   23.29   (209.67 255.00) [210 255] (46)
251   15.69   23.30   (210.40 255.00) [210 255] (46)
252   15.75   23.31   (211.14 255.00) [211 255] (45)
253   15.81   23.32   (211.87 255.00) [212 255] (44)
254   15.88   23.33   (212.60 255.00) [213 255] (43)
255   15.94   23.34   (213.33 255.00) [213 255] (43)
 |#

(let* ((f0  500)
       (fsamp 32000)
       (nfft 512)
       (hz/cell (float (/ fsamp nfft)))
       (r>  (expt 2 1/3))
       (r<  (/ r>))
       (f0  (* f0 (sqrt r<)))
       (f>  (loop for ix from 0 below 17
                  for f = f0 then (* f r>)
                  collect (list f (/ f hz/cell))))
       (f<  (loop for ix from 0 below 12
                  for f = f0 then (* f r<)
                  collect (list f (/ f hz/cell)))))
  (inspect (print f>)))

                  
