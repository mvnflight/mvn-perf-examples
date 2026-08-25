package lib03;

import demo.Core;

/** Independent library module; depends only on {@code core}. */
public final class Lib03 {
    public String name() {
        return new Core().name() + "+lib-03";
    }
}
