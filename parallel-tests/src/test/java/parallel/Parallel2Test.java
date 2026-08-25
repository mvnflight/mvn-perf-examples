package parallel;

import demo.DemoSleep;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertTrue;

/** Independent 15 s test, own class so forkCount can run it in its own fork JVM.
 *  See {@link Parallel1Test} for the intra-module test-parallelism rationale. */
class Parallel2Test {
    @Test
    void slowTest() {
        assertTrue(new ParallelTests().name().endsWith("parallel-tests"));
        DemoSleep.sleepMillis(15_000);
    }
}
