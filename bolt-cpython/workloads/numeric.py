# n-body simulation, the classic one: floats, attribute-free tuples and
# lists, tight loops. hits the arithmetic and loop parts of the interpreter.
import sys
import time

PI = 3.14159265358979323
SOLAR_MASS = 4 * PI * PI
DAYS_PER_YEAR = 365.24


def bodies():
    return [
        # sun
        [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0], SOLAR_MASS],
        # jupiter
        [[4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01],
         [1.66007664274403694e-03 * DAYS_PER_YEAR, 7.69901118419740425e-03 * DAYS_PER_YEAR,
          -6.90460016972063023e-05 * DAYS_PER_YEAR],
         9.54791938424326609e-04 * SOLAR_MASS],
        # saturn
        [[8.34336671824457987e+00, 4.12479856412430479e+00, -4.03523417114321381e-01],
         [-2.76742510726862411e-03 * DAYS_PER_YEAR, 4.99852801234917238e-03 * DAYS_PER_YEAR,
          2.30417297573763929e-05 * DAYS_PER_YEAR],
         2.85885980666130812e-04 * SOLAR_MASS],
        # uranus
        [[1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01],
         [2.96460137564761618e-03 * DAYS_PER_YEAR, 2.37847173959480950e-03 * DAYS_PER_YEAR,
          -2.96589568540237556e-05 * DAYS_PER_YEAR],
         4.36624404335156298e-05 * SOLAR_MASS],
        # neptune
        [[1.53796971148509165e+01, -2.59193146099879641e+01, 1.79258772950371181e-01],
         [2.68067772490389322e-03 * DAYS_PER_YEAR, 1.62824170038242295e-03 * DAYS_PER_YEAR,
          -9.51592254519715870e-05 * DAYS_PER_YEAR],
         5.15138902046611451e-05 * SOLAR_MASS],
    ]


def advance(system, pairs, dt, steps):
    for _ in range(steps):
        for ((p1, v1, m1), (p2, v2, m2)) in pairs:
            dx = p1[0] - p2[0]
            dy = p1[1] - p2[1]
            dz = p1[2] - p2[2]
            mag = dt * ((dx * dx + dy * dy + dz * dz) ** -1.5)
            b1 = m1 * mag
            b2 = m2 * mag
            v1[0] -= dx * b2
            v1[1] -= dy * b2
            v1[2] -= dz * b2
            v2[0] += dx * b1
            v2[1] += dy * b1
            v2[2] += dz * b1
        for (p, v, _) in system:
            p[0] += dt * v[0]
            p[1] += dt * v[1]
            p[2] += dt * v[2]


def energy(system, pairs):
    e = 0.0
    for ((p1, _, m1), (p2, _, m2)) in pairs:
        dx = p1[0] - p2[0]
        dy = p1[1] - p2[1]
        dz = p1[2] - p2[2]
        e -= (m1 * m2) / ((dx * dx + dy * dy + dz * dz) ** 0.5)
    for (_, v, m) in system:
        e += m * (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]) / 2.0
    return e


def main(n):
    system = bodies()
    pairs = [(system[i], system[j]) for i in range(len(system)) for j in range(i + 1, len(system))]
    t0 = time.perf_counter()
    advance(system, pairs, 0.01, n * 20000)
    t1 = time.perf_counter()
    print(f"workload=numeric n={n} time={t1 - t0:.4f}s checksum={energy(system, pairs):.9f}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 10)
