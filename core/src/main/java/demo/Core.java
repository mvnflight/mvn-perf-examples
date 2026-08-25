package demo;

/** Foundation module: everyone depends on it, so it gates the start of the build. */
public final class Core {
    public String name() {
        return "core";
    }
}
