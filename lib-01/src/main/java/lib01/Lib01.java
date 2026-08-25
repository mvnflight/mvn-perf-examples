package lib01;

import demo.Core;

/** Independent library module; depends only on {@code core}. */
public final class Lib01 {
    public String name() {
        return new Core().name() + "+lib-01";
    }
}
