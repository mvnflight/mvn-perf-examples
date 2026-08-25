package pipe1;

import demo.Core;

/** First link of the critical-path chain; depends on {@code core}. */
public final class Pipe1 {
    public String name() {
        return new Core().name() + "+pipe-1";
    }
}
