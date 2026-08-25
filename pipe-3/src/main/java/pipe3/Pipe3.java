package pipe3;

import pipe2.Pipe2;

/** Third link of the critical-path chain; depends on {@code pipe-2}. */
public final class Pipe3 {
    public String name() {
        return new Pipe2().name() + "+pipe-3";
    }
}
