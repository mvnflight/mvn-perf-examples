package demo;

import java.util.Random;

/**
 * Test pause helper for this example reactor. Every test method's body is just a
 * call to {@link #sleep()}; the duration is what mvnflight measures, so the
 * reactor's per-module weight comes entirely from here.
 *
 * <p>Durations are <b>fixed per module</b>: each module's pom sets
 * {@code demo.sleep.minMs == demo.sleep.maxMs}, so the pause is a deterministic
 * value (the span is zero, so the seeded RNG never varies it). That keeps the
 * numbers identical across the {@code -T1..-T10} grid and across the default vs
 * smart builder, so the published reports are directly comparable. When
 * {@code minMs < maxMs} the pause is instead a reproducible pseudo-random value
 * seeded by the test method name (set {@code -Ddemo.sleep.random=true} for a
 * genuinely random pause).
 *
 * <p>Knobs (all forwarded into the forked test JVM by the parent pom's surefire
 * config; command-line {@code -D} overrides the pom values):
 * <ul>
 *   <li>{@code demo.sleep.minMs} / {@code demo.sleep.maxMs} — set equal per module
 *       for a fixed duration (core/app 2 s, libs 18 s, pipe links 8 s)</li>
 *   <li>{@code demo.sleep.seed}  (default 42; only used when min &lt; max)</li>
 *   <li>{@code demo.sleep.random} (default false; only used when min &lt; max)</li>
 *   <li>{@code demo.weight} (default 1.0 — global time scale, e.g. 0.2 = 20 %)</li>
 * </ul>
 */
public final class DemoSleep {

    private DemoSleep() {
    }

    /** Sleep for a duration keyed on the calling test method. */
    public static void sleep() {
        StackTraceElement caller = Thread.currentThread().getStackTrace()[2];
        sleep(caller.getClassName() + "#" + caller.getMethodName());
    }

    /**
     * Sleep for a fixed base duration in milliseconds, scaled by {@code demo.weight}
     * (so {@code -Ddemo.weight=0.2} shrinks it like every other pause, and the
     * warm-up {@code -Ddemo.weight=0} build skips it entirely). Unlike {@link #sleep()}
     * this ignores {@code demo.sleep.minMs/maxMs}, so a module whose fixed per-module
     * duration is something else (parallel-tests inherits the 2 s default) can still
     * host tests of an explicit, different length — used by the parallel-tests
     * module's five 15 s fork tests.
     */
    public static void sleepMillis(long baseMillis) {
        long millis = Math.max(0L, Math.round(Math.max(0L, baseMillis) * parseWeight()));
        try {
            Thread.sleep(millis);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    /** Sleep for a duration keyed on the given stable {@code key}. */
    public static void sleep(String key) {
        long min = Long.getLong("demo.sleep.minMs", 10L);
        long max = Long.getLong("demo.sleep.maxMs", 10_000L);
        long seed = Long.getLong("demo.sleep.seed", 42L);
        boolean random = Boolean.getBoolean("demo.sleep.random");
        double weight = parseWeight();

        long span = Math.max(0L, max - min);
        Random rng = random ? new Random() : new Random(seed ^ (long) key.hashCode());
        long base = min + (span == 0L ? 0L : (long) (rng.nextDouble() * span));
        long millis = Math.max(0L, Math.round(base * weight));

        try {
            Thread.sleep(millis);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    private static double parseWeight() {
        try {
            return Double.parseDouble(System.getProperty("demo.weight", "1.0"));
        } catch (NumberFormatException e) {
            return 1.0;
        }
    }
}
