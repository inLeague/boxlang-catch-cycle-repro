/**
 * Control: same class shape but a NORMAL (linear) cause chain — terminates.
 */
public class LinearException extends RuntimeException {
    public LinearException( String message ) {
        super( message );
        this.initCause( new RuntimeException( "root cause" ) );
    }
}
