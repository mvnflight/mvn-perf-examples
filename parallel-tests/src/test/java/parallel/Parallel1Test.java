package parallel;

import demo.DemoSleep;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * One of five independent 15-second tests in parallel-tests, each kept in its OWN
 * class so Surefire's forkCount knob (demo.forkCount, default 1) can fan them out
 * across parallel forked JVMs. At forkCount=1 they run serially (~75 s); at
 * forkCount=5 mvn-lens shows one fork lane per JVM running concurrently and the
 * module's whole test phase collapses to ~15 s — that is the intra-module
 * test-parallelism story, published under /parallel/. The class name ends in
 * {@code Test} so Surefire's default include pattern picks it up. See the parent
 * POM's surefire {@code <forkCount>} and the grid legs in
 * .github/workflows/fork-grid.yml.
 */
class Parallel1Test {
    @Test
    void slowTest() {
        assertTrue(new ParallelTests().name().endsWith("parallel-tests"));
        DemoSleep.sleepMillis(15_000);
    }
}
