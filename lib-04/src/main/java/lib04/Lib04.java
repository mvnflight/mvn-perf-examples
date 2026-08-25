package lib04;

import demo.Core;

/** Independent library module; depends only on {@code core}. */
public final class Lib04 {
    public String name() {
        return new Core().name() + "+lib-04";
    }
}
