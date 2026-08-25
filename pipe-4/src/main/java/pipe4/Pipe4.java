package pipe4;

import pipe3.Pipe3;

/** Final link of the critical-path chain; depends on {@code pipe-3}. */
public final class Pipe4 {
    public String name() {
        return new Pipe3().name() + "+pipe-4";
    }
}
