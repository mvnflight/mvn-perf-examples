package parallel;

import demo.Core;

/** Independent library module; depends only on {@code core}. Host for the
 *  intra-module test-parallelism demo (see {@code Parallel1Test..Parallel5Test}). */
public final class ParallelTests {
    public String name() {
        return new Core().name() + "+parallel-tests";
    }
}
