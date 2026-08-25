package pipe2;

import pipe1.Pipe1;

/** Second link of the critical-path chain; depends on {@code pipe-1}. */
public final class Pipe2 {
    public String name() {
        return new Pipe1().name() + "+pipe-2";
    }
}
