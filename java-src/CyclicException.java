/**
 * A RuntimeException with a CYCLIC cause chain: two nodes, each the other's cause.
 * getCause() therefore never returns null (the walk a->b->a->b... is infinite).
 *
 * Java forbids direct self-cause via initCause("Self-causation not permitted")
 * and forbids passing `this` to super(), so the minimal constructible cycle is
 * two nodes: a.cause = b, then b.initCause(a).
 */
public class CyclicException extends RuntimeException {
    public CyclicException( String message ) {
        super( message );
        RuntimeException b = new RuntimeException( "cycle-node-b" );
        this.initCause( b );      // this.cause = b
        b.initCause( this );      // b.cause = this  =>  this -> b -> this -> ...
    }
}

