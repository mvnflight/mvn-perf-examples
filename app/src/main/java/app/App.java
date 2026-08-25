package app;

import lib01.Lib01;
import lib02.Lib02;
import lib03.Lib03;
import lib04.Lib04;
import pipe4.Pipe4;

/**
 * Aggregator: depends on the four filler libs and on {@code pipe-4} (the tip of
 * the pipe-1 → … → pipe-4 chain), so it gates the end of the build.
 */
public final class App {
    public int moduleCount() {
        int count = 1; // core
        count += new Lib01().name().isEmpty() ? 0 : 1;
        count += new Lib02().name().isEmpty() ? 0 : 1;
        count += new Lib03().name().isEmpty() ? 0 : 1;
        count += new Lib04().name().isEmpty() ? 0 : 1;
        // Pipe4#name() walks the whole chain: "core+pipe-1+pipe-2+pipe-3+pipe-4".
        // Each '+' marks one pipe module, so the count of '+' is the chain length.
        count += (int) new Pipe4().name().chars().filter(c -> c == '+').count();
        return count + 1; // app
    }
}
