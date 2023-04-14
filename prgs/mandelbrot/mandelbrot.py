a = 0
b = 0


def neg8(x):
    x ^= 0xff
    x += 1
    return x


def abs8(x):
    if x >= 128:
        return neg8(x)

    return x


def sign(x, y):
    x_neg = x >= 128

    y_neg = y >= 128

    return 1 if (x_neg and y_neg) or (not x_neg and not y_neg) else -1


# for i in range(256):
#     print(i, abs8(i))


for i in range(64):
    for j in range(64):
        z_im = 0
        z_re = 0

        c_re = (j - 48) & 0xff
        c_im = (i - 32) & 0xff

        # print(i, j, c_re, c_im)

        # c_re = j
        # c_im = i

        out = False
        for itr in range(64):
            re_sq = ((abs8(z_re)**2) >> 5) & 0xff
            im_sq = ((abs8(z_im)**2) >> 5) & 0xff

            z_im = (((abs8(z_re) * abs8(z_im) * sign(z_im, z_re)) >> 4) + c_im) & 0xff  # 2 * a * b
            z_re = (((re_sq + neg8(im_sq)) & 0xff) + c_re) & 0xff

            if re_sq + im_sq >= 4 * 32:
                out = True
                break

        # z = 0 + 0j
        #
        # c = complex(-1.5 + (1/32 * j), (-1 + (1/32 * i)))
        # out = False
        # for itr in range(64):
        #     if abs(z) > 2:
        #         out = True
        #         break
        #     z = z**2 + c

        # z_re = 0
        # z_im = 0
        #
        # c = complex(-1 + (1 / 32 * j), (-1 + (1 / 32 * i)))
        # c_re = c.real
        # c_im = c.imag
        #
        # out = False
        # for itr in range(64):
        #     if z_re**2 + z_im**2 > 2:
        #         out = True
        #         break
        #
        #     z_re, z_im = z_re**2 - z_im**2 + c_re, 2*z_re*z_im + c_im


        if out:
            print(' ', end='')
        else:
            print('#', end='')

    # if itr < 4:
        #     print(' ', end='')
        # elif itr < 8:
        #     print('.', end='')
        # elif itr < 16:
        #     print('o', end='')
        #
        # else:
        #     print('#', end='')

    print()