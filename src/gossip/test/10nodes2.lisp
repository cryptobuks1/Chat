;;; 10nodes2.lisp
;;; Saved graph file.
;;; Call gossip::restore-graph-from-file on this file to restore graph from it.

;;; Interesting graph. Start at node9.

(in-package :gossip)

(make-node ':gossip
  :UID 9
  :NEIGHBORS '(2 4)
  :LOGFN 'INTERACTIVE-LOGGING-FUNCTION
  :local-kvs (as-hash-table
  'EQUAL
  'NIL)
 )
(make-node ':gossip
  :UID 4
  :NEIGHBORS '(8 3 5 9)
  :LOGFN 'DEFAULT-LOGGING-FUNCTION
  :local-kvs (as-hash-table
  'EQUAL
  'NIL)
 )
(make-node ':gossip
  :UID 5
  :NEIGHBORS '(6 8 4)
  :LOGFN 'DEFAULT-LOGGING-FUNCTION
  :local-kvs (as-hash-table
  'EQUAL
  'NIL)
 )
(make-node ':gossip
  :UID 8
  :NEIGHBORS '(4 3 5)
  :LOGFN 'DEFAULT-LOGGING-FUNCTION
  :local-kvs (as-hash-table
  'EQUAL
  'NIL)
 )
(make-node ':gossip
  :UID 3
  :NEIGHBORS '(4 1 8)
  :LOGFN 'DEFAULT-LOGGING-FUNCTION
  :local-kvs (as-hash-table
  'EQUAL
  'NIL)
 )
(make-node ':gossip
  :UID 1
  :NEIGHBORS '(2 6 3)
  :LOGFN 'DEFAULT-LOGGING-FUNCTION
  :local-kvs (as-hash-table
  'EQUAL
  'NIL)
 )
(make-node ':gossip
  :UID 6
  :NEIGHBORS '(5 2 1)
  :LOGFN 'DEFAULT-LOGGING-FUNCTION
  :local-kvs (as-hash-table
  'EQUAL
  'NIL)
 )
(make-node ':gossip
  :UID 2
  :NEIGHBORS '(9 1 7 6)
  :LOGFN 'DEFAULT-LOGGING-FUNCTION
  :local-kvs (as-hash-table
  'EQUAL
  'NIL)
 )
(make-node ':gossip
  :UID 7
  :NEIGHBORS '(10 2)
  :LOGFN 'DEFAULT-LOGGING-FUNCTION
  :local-kvs (as-hash-table
  'EQUAL
  'NIL)
 )
(make-node ':gossip
  :UID 10
  :NEIGHBORS '(7)
  :LOGFN 'DEFAULT-LOGGING-FUNCTION
  :local-kvs (as-hash-table
  'EQUAL
  'NIL)
 )
