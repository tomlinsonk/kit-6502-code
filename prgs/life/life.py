import pygame
import numpy as np
import time

rows = 64
cols = 64

BLACK = (0, 0, 0)
WHITE = (255, 255, 255)

colors = [BLACK, WHITE]

# grid = np.zeros((102, 102), dtype=np.int64)
grid = np.random.randint(0, 2, size=(cols+2, rows+2))


def update_display(display, grid):
    for i in range(1, rows+1):
        for j in range(1, cols+1):
            pygame.draw.rect(display, colors[grid[i, j]], ((j-1)*10, (i-1)*10, 10, 10))


def update_grid(grid):
    live_neighbors = np.zeros_like(grid)
    for i in range(1, rows+1):
        for j in range(1, cols+1):
            live_neighbors[i, j] = grid[i+1, j] + grid[i-1, j] + grid[i, j+1] + grid[i, j-1] \
                                   + grid[i+1, j+1] + grid[i+1, j-1] + grid[i-1, j+1] + grid[i-1, j-1]

    return np.logical_or(live_neighbors == 3, np.logical_and(live_neighbors == 2, grid == 1)).astype(np.int64)


if __name__ == '__main__':
    pygame.init()
    display = pygame.display.set_mode((rows*10, cols*10))
    pygame.display.set_caption('Conway\'s Game of Life')

    running = True

    display.fill(BLACK)

    update_display(display, grid)
    pygame.display.update()

    while running:
        for event in pygame.event.get():

            if event.type == pygame.QUIT:
                running = False

        # time.sleep(0.2)

        grid = update_grid(grid)
        update_display(display, grid)
        pygame.display.update()
