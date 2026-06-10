/*
 * Intentional taint path for dataflow fixture (Java):
 *   recvPacket  (source)
 *     → parseMsg(buf)
 *       → execCmd(cmd)   (sink — Runtime.exec)
 *
 * Also contains environment-branch example for env_branches query.
 */
public class Processor {

    /* sink */
    public void execCmd(String cmd) throws Exception {
        Runtime.getRuntime().exec(cmd);
    }

    /* taint propagation */
    public void parseMsg(String buf) throws Exception {
        String cmd = buf.trim();
        execCmd(cmd);
    }

    /* source: externally-supplied data */
    public void recvPacket(String data) throws Exception {
        parseMsg(data);
    }

    /* environment-sensitive branch — flagged by env_branches query */
    public void configure() {
        String mode = System.getenv("APP_MODE");    // env branch
        if ("production".equals(mode)) {
            initProd();
        } else if ("staging".equals(mode)) {
            initStaging();
        } else {
            initDev();
        }
    }

    private void initProd()    { /* prod init */ }
    private void initStaging() { /* staging init */ }
    private void initDev()     { /* dev init */ }

    public static void main(String[] args) throws Exception {
        Processor p = new Processor();
        if (args.length > 0) {
            p.recvPacket(args[0]);
        }
        p.configure();
    }
}
