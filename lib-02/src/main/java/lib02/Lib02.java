package lib02;

import demo.Core;

/** Independent library module; depends only on {@code core}. */
public final class Lib02 {
    public String name() {
        return new Core().name() + "+lib-02";
    }
}
