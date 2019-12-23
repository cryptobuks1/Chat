;; rb-trees.lisp -- Immutable Functional Red-Black Trees
;; --------------------------------------------------------------------------------------
;; Binary tree storage for unique ordered items, plus Maps, FIFO Queues, and Stacks
;;
;; Copyright (C) 2008 by SpectroDynamics, LLC. All rights reserved.
;;
;; DM/SD  08/08
;; DM/RAL 02/17 - carefully recrafted. Tests show that direct use of stack is much faster
;;                than using S(1) eval schemes, such as CPS style recoding or manual stacking
;;                of intermediate results.
;; --------------------------------------------------------------------------------------
#|
The MIT License

Copyright (c) 2017-2018 Refined Audiometrics Laboratory, LLC

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
|#

;; ------------------------------------------------------------------------
(in-package :sets)
;; ------------------------------------------------------------------------
;; equiv to #F
(declaim  (OPTIMIZE (SPEED 3) #|(SAFETY 0)|# #+:LISPWORKS (FLOAT 0))
          (inline empty singleton create))

;; ----------------------------------------------------------------
;; Sets are represented by balanced binary trees
;; The heights of children differ by at most 2
;; Tree nodes are quadruples (l v r h) where:
;;   - l = left child
;;   - v = value
;;   - r = right child
;;   - h = node height, empty node has height 0
;; ----------------------------------------------------------------

;; ------------------------------------------------------
;; Types & Public seed constructors - EMPTY, SINGLETON

(defclass tree ()
  ())

(defclass empty (tree)
  ())

(defmethod is-empty ((x empty))
  t)

(defmethod height ((x empty))
  0)

(defvar +empty+
  (make-instance 'empty))

(defun empty ()
  +empty+)


(defclass node (tree)
  ((l  :reader node-l  :initarg :l  :initform +empty+  :type tree)
   (v  :reader node-v  :initarg :v)
   (r  :reader node-r  :initarg :r  :initform +empty+  :type tree)
   (h  :reader node-h  :initarg :h  :initform 1        :type fixnum)
   ))

(defmethod is-empty ((x node))
  nil)

(defmethod height ((x node))
  (node-h x))

(defun singleton (x)
  (make-instance 'node
   :v  x))

;; ------------------------------------------------------
;; helpful macros...

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun is-wild? (sym)
    (string= "_" (symbol-name sym)))
  (defun gen-ignore_ (syms)
    (um:when-let (sym (find-if #'is-wild? syms))
      `((declare (ignore ,sym)))
      )))
  
(defmacro with-node-bindings (lvrh-syms node &body body)
  ;; Intended only to destructure tree nodes.  Every instance is
  ;; expected to have 4 symbols in lvrh-syms pattern, corresponding to
  ;; (l v r h) l = left, v = val, r = right, h = height.
  (let ((bindings (delete-if #'is-wild?
                             (um:zip lvrh-syms '(node-l node-v node-r node-h))
                             :key #'car)))
    `(with-accessors ,bindings ,node
       ,@body)))

#+:LISPWORKS
(editor:setup-indent "with-node-bindings" 2)

(defmacro with-list-bindings (syms lst &body body)
  ;; intended for general top-level list destructuring
  ;; all symbols are optionally bound to list elements
  `(multiple-value-bind ,syms (values-list ,lst)
     ,@(gen-ignore_ syms)
     ,@body))

#+:LISPWORKS
(editor:setup-indent "with-list-bindings" 2)

;; ------------------------------------------------------
;; private constructors... CREATE, BAL

;; create - create a tree node with left son l, value v, and right son r.
;; We must have all elements of l < v < all elements of r.
;; l and r must be balanced and have a height difference <= 2
;; (intended for internal use only)

(defun create (l v r &optional (hl (height l)) (hr (height r)))
  (declare (fixnum hl hr))
  (make-instance 'node
   :l  l  :v  v  :r  r
   :h  (the fixnum (1+ (max hl hr)))))

;; bal - same as create, but performs one step of rebalancing if necessary
;; assumes l and r balanced and height difference <= 3
;; (intended for internal use only)

(defun bal (l v r)
  (let ((hl (height l))
        (hr (height r)))
    (declare (fixnum hl hr))
    (cond ((> hl (the fixnum (+ 2 hr)))
           (with-node-bindings (ll lv lr) l
             (cond ((>= (the fixnum (height ll))
                        (the fixnum (height lr)))
                    (create ll lv (create lr v r)))
                   
                   (t  (with-node-bindings (lrl lrv lrr) lr
                         (create (create ll lv lrl) lrv (create lrr v r))))
                   )))

          ((> hr (the fixnum (+ 2 hl)))
           (with-node-bindings (rl rv rr) r
             (cond ((>= (the fixnum (height rr))
                        (the fixnum (height rl)))
                    (create (create l v rl) rv rr))
                   
                   (t  (with-node-bindings (rll rlv rlr) rl
                         (create (create l v rll) rlv (create rlr rv rr))))
                   )))
          
          (t  (create l v r hl hr))
          )))
            
;; -----------------------------------------------------------
;; add - insertion of one element

(defvar *replace-p* nil)

(defmacro with-replacement (&body body)
  `(let ((*replace-p* t))
     ,@body))

(defmacro without-replacement (&body body)
  `(let ((*replace-p* nil))
     ,@body))

(defmacro with-replacement-p (tf &body body)
  `(let ((*replace-p* ,tf))
     ,@body))

(defmethod add (x (tree empty))
  (values (singleton x) t))

(defmethod add (x (tree node))
  ;; execute with S(Log2(N))
  (with-node-bindings (l v r h) tree
    (cond ((eq x v)  tree)
          (t  (let ((c (ord:compare x v)))
                (declare (real c))
                (cond ((zerop c)
                      ;; in zero case - to support maps (see below)
                      ;; ensure that new map value is substituted for old
                      ;; value - use x instead of v for value field of result.
                      (if *replace-p*
                          (make-instance 'node
                                         :l l :v x :r r :h h)
                        tree))
                      
                      ((minusp c)
                       (multiple-value-bind (new-left needs-rebal) (add x l)
                         (cond ((eq l new-left)  tree)
                               (needs-rebal      (values (bal new-left v r) t))
                               (t                (create new-left v r))
                               )))
                      
                      (t
                       (multiple-value-bind (new-right needs-rebal) (add x r)
                         (cond ((eq r new-right)  tree)
                               (needs-rebal       (values (bal l v new-right) t))
                               (t                 (create l v new-right))
                               )))
                      )))
          )))

;; -----------------------------------------------------------
;; join -- same as create and bal, but no assumptions are made on the
;; relative heights of l and r

(defmethod join ((l empty) v r)
  (add-min-elt v r))

(defmethod join (l v (r empty))
  (add-max-elt v l))

(defmethod add-min-elt (v (s empty))
  (singleton v))

(defmethod add-min-elt (v (s node))
  (with-node-bindings (l x r) s
    (bal (add-min-elt v l) x r)))

(defmethod add-max-elt (v (s empty))
  (singleton v))

(defmethod add-max-elt (v (s node))
  (with-node-bindings (l x r) s
    (bal l x (add-max-elt v r))))

(defmethod join ((l node) v (r node))
  ;; execute with S(Log2(N))
  (with-node-bindings (ll lv lr lh) l
    (with-node-bindings (rl rv rr rh) r
      (cond  ((> lh (the fixnum (+ 2 rh)))
              (bal ll lv (join lr v r)))
             
             ((> rh (the fixnum (+ 2 lh)))
              (bal (join l v rl) rv rr))
             
             (t (create l v r lh rh))
             ))))

;; ------------------------------------------------------------------------

(defun not-found ()
  (error "Not found"))

;; min-elt -- return the value of the smallest element of the set
;; i.e., the value from the leftmost node

(defmethod min-elt ((tree empty))
  (not-found))

(defmethod min-elt ((tree node))
  ;; execute with S(1)
  (with-node-bindings (l v) tree
    (cond ((is-empty l)  v)
          (t             (min-elt l))
          )))

;; remove-min-elt - remove the smallest element of the set
;; i.e., remove the leftmost node

(defmethod remove-min-elt ((tree empty))
  (not-found))

(defmethod remove-min-elt ((tree node))
  ;; execute with S(Log2(N))
  (with-node-bindings (l v r) tree
    (cond ((is-empty l)  r)
          (t             (bal (remove-min-elt l) v r))
          )))

;; concat - merge two trees l and r into one.
;; All elements of l must precede the elements of r.
;; No assumptions on the heights of l and r.

(defmethod concat ((t1 empty) t2)
  t2)

(defmethod concat (t1 (t2 empty))
  t1)

(defmethod concat ((t1 node) (t2 node))
  (join t1 (min-elt t2) (remove-min-elt t2)))

;; ------------------------------------------------------------------------

(defmethod max-elt ((tree empty))
  (not-found))

(defmethod max-elt ((tree node))
  ;; execute with S(1)
  (with-node-bindings (_ v r) tree
    (cond ((is-empty r)  v)
          (t             (max-elt r))
          )))

;; remove-max-elt -- remove the largest element of the set
;; also useful for priority-queues

(defmethod remove-max-elt ((tree empty))
  (not-found))

(defmethod remove-max-elt ((tree node))
  ;; execute with S(Log2(N))
  (with-node-bindings (l v r) tree
    (cond ((is-empty r)  l)
          (t             (bal l v (remove-max-elt r)))
          )))

;; ------------------------------------------------------------------------
;; split - (split x s) returns a triple of (values l present r)
;; where
;; - l is the set of elements of s that are < x
;; - r is the set of elements of s that are > x
;; - present is nil if s contains no element equal to x, or else
;;   present is the set whose top node contains an element equal to x

(defmethod split (x (tree empty))
  (list (empty) nil (empty)))

(defmethod split (x (tree node))
  ;; for internal use
  ;; execute with S(Log2(N))
  (with-node-bindings (l v r) tree
    (let ((c (ord:compare x v)))
      (declare (real c))
      (cond ((zerop c)  (list l tree r))
            ((minusp c)
             (with-list-bindings (ll pres rl) (split x l)
               (list ll pres (join rl v r))))
            (t
             (with-list-bindings (lr pres rr) (split x r)
               (list (join l v lr) pres rr)))
            ))))

;; ------------------------------------------------------------------------

(defmethod mem (x (tree empty))
  nil)

(defmethod mem (x (tree node))
  ;; execute with S(1)
  (with-node-bindings (l v r) tree
    (let ((c (ord:compare x v)))
      (declare (real c))
      (if (zerop c)
          (values t v)
        (mem x (if (minusp c) l r)))
      )))

;; ------------------------------------------------------------------------

(defmethod remove (x (tree empty))
  tree)

(defmethod merge-trees ((t1 empty) t2)
  t2)

(defmethod merge-trees (t1 (t2 empty))
  t1)

(defmethod merge-trees ((t1 node) (t2 node))
  ;; merge -- merge two trees l and r into one.
  ;; All elements of l must precede the elements of r
  ;; Assume height difference <= 2
  ;; (for internal use)
  (bal t1 (min-elt t2) (remove-min-elt t2)))

(defmethod remove (x (tree node))
  ;; execute with S(Log2(N))
  (with-node-bindings (l v r) tree
    (let ((c (ord:compare x v)))
      (declare (real c))
      (cond ((zerop c)  (merge-trees l r))
            ((minusp c) (bal (remove x l) v r))
            (t          (bal l v (remove x r)))
            ))))

;; ------------------------------------------------------------------------

(defmethod union ((s1 empty) s2)
  s2)

(defmethod union (s1 (s2 empty))
  s1)

(defmethod union ((s1 node) (s2 node))
  ;; execute with S(Log2(N))
  (with-node-bindings (l1 v1 r1 h1) s1
    (with-node-bindings (l2 v2 r2 h2) s2
      (cond ((>= h1 h2)
             (cond ((= h2 1)  (add v2 s1))
                   (t  (with-list-bindings (l2 _ r2) (split v1 s2)
                         (join (union l1 l2) v1 (union r1 r2))))
                   ))
            
            (t (cond ((= h1 1)  (add v1 s2))
                     (t  (with-list-bindings (l1 _ r1) (split v2 s1)
                           (join (union l1 l2) v2 (union r1 r2))))
                     ))
            ))))

;; ------------------------------------------------------------------------

(defmethod intersection ((s1 empty) s2)
  (empty))

(defmethod intersection (s1 (s2 empty))
  (empty))

(defmethod intersection ((s1 node) (s2 node))
  ;; execute with S(Log2(N))
  (with-node-bindings (l1 v1 r1) s1
    (with-list-bindings (l2 ans r2) (split v1 s2)
      (let ((new-l (intersection l1 l2))
            (new-r (intersection r1 r2)))
        (cond (ans  (join new-l v1 new-r))
              (t    (concat new-l new-r))
              )))))

;; ------------------------------------------------------------------------

(defmethod diff ((s1 empty) s2)
  s1)

(defmethod diff (s1 (s2 empty))
  s1)

(defmethod diff ((s1 node) (s2 node))
  ;; execute with S(Log2(N))
  (with-node-bindings (l1 v1 r1) s1
    (with-list-bindings (l2 ans r2) (split v1 s2)
      (let ((new-l  (diff l1 l2))
            (new-r  (diff r1 r2)))
        (cond (ans  (concat new-l new-r))
              (t    (join new-l v1 new-r))
              )))))

;; ------------------------------------------------------------------------

(defmethod cons-enum ((s empty) e)
  e)

(defmethod cons-enum ((s node) e)
  ;; proceeding down the left side from node s
  ;; form a telescoped list of node vals and right nodes
  ;;   -> (v1 r1 (v2 r2 (v3 r3 (... (vtop rtop e))) ...) (why? used internally)
  ;; where, v1   is the min element of set s,
  ;;        r1   is the right subnode of the min element node,
  ;;        v2   is the value from the parent node of the min element node,
  ;;        r2   is the right subnode of the parent node,
  ;;        ...
  ;;        vtop is the value in the top node,
  ;;        rtop is the right subnode of the top node, and
  ;;        e    is the starting accumulator list
  (with-node-bindings (l v r) s
    (cons-enum l (list v r e))))

(defmethod compare-enums ((e1 null) (e2 null))
  0)

(defmethod compare-enums ((e1 null) e2)
  -1)

(defmethod compare-enums (e1 (e2 null))
  1)

(defmethod compare-enums ((e1 cons) (e2 cons))
  (with-list-bindings (v1 r1 t1) e1
    (declare (list r1 t1))
    (with-list-bindings (v2 r2 t2) e2
      (declare (list r2 t2))
      (let ((c (ord:compare v1 v2)))
        (declare (real c))
        (cond ((zerop c)  (iter (cons-enum r1 t1)
                                (cons-enum r2 t2)))
              (t  c)
              )))))

(defmethod ord:compare ((s1 tree) (s2 tree))
  ;; execute with S(Log2(N))
  (compare-enums (cons-enum s1 nil)
                 (cons-enum s2 nil)))

;; ------------------------------------------------------------------------

(defmethod subset ((s1 empty) s2)
  t)

(defmethod subset (s1 (s2 empty))
  nil)

(defmethod subset ((s1 node) (s2 node))
  ;; return true if s1 is subset of s2
  ;; execute with S(Log2(N))
  (with-node-bindings (l1 v1 r1) s1
    (with-node-bindings (l2 v2 r2) s2
      (let ((c (ord:compare v1 v2)))
        (declare (real c))
        (cond ((zerop c)
               (and (subset l1 l2)
                    (subset r1 r2)))
              
              ((minusp c)
               (and (subset (make-instance 'node
                                 :l l1  :v v1)
                                l2)
                    (subset r1 s2)))
              
              (t (and (subset (make-instance 'node
                                   :v v1  :r r1)
                                  r2)
                      (subset l1 s2)))
              )))))

;; --------------------------------------------------------

(defmethod iter (fn (s empty))
  (values))

(defmethod iter (fn (s node))
  ;; perform fn on every set element in pre-order
  ;; execute with S(Log2(N))
  ;; speed 1.0
  (with-node-bindings (l v r) s
    (iter fn l)
    (funcall fn v)
    (iter fn r)))

(defmethod fold (fn (s empty) accu)
  accu)

(defmethod fold (fn (s node) accu)
  ;; accumulate fn applied to every set element in pre-order
  ;; execute with S(Log2(N))
  (with-node-bindings (l v r) s
    (fold fn r
          (funcall fn v (fold fn l accu)))))

(defmethod every (pred (s empty))
  t)

(defmethod every (pred (s node))
  ;; return true if every set element satisfies pred
  ;; execute with S(Log2(N))
  (with-node-bindings (l v r) s
    (and (funcall pred v)
         (every pred l)
         (every pred r))))


(defmethod some (pred (s empty))
  nil)

(defmethod some (pred (s node))
  ;; return true of some element of s satisfies pred
  ;; Execute with S(Log2(N))
  (with-node-bindings (l v r) s
    (or (funcall pred v)
        (some pred l)
        (some pred r))))

(defmethod filter (pred (s tree))
  (filter-aux pred s (empty)))

(defmethod filter-aux (pred (s empty) accu)
  accu)

(defmethod filter-aux (pred (s node) accu)
  ;; return subset consisting of element that satisfy pred.
  ;; Execute with S(Log2(N))
  (with-node-bindings (l v r) s
    (let ((new-accu (filter-aux pred l accu)))
      (filter-aux pred r (if (funcall pred v)
                             (add v new-accu)
                           new-accu)))))

(defmethod partition (pred (s tree))
  (partition-aux pred s (list (empty) (empty))))

(defmethod partition-aux (pred (s empty) pair)
  pair)

(defmethod parition-aux (pred (s node) pair)
  ;; partition set into two subsets (true-element, false-elements)
  ;; according to pred. Execute with S(Log2(N))
  (with-node-bindings (l v r) s
    (with-list-bindings (tp fp) (partition-aux pred l pair)
      (partition-aux pred r (if (funcall pred v)
                                (list (add v tp) fp)
                              (list tp (add v fp))))
      )))

(defmethod cardinal ((s empty))
  0)

(defmethod cardinal ((s node))
  ;; count elements in s (pre-order, FWIW), using S(Log2(N))
  (with-node-bindings (l _ r) s
    (+ (cardinal l) 1 (cardinal r))))

(defmethod elements ((s tree))
  (elements-aux s nil))

(defmethod elements-aux ((s empty) accu)
  accu)

(defmethod elements-aux ((s node) accu)
  ;; list elements of set in pre-order, using S(1)
  (with-node-bindings (l v r) s
    (elements-aux l (cons v (elements-aux r accu)))))


(defmethod choose ((s tree))
  (min-elt s))

;; -------------------------------------------------------------

#|
(defun make-tree (&optional (tree (sets:empty)))
  (if (= (sets:height tree) 10)
      tree
    (make-tree (sets:add (random 16384) tree))))

#+:LISPWORKS
(capi:contain
 (make-instance 'capi:graph-pane
                :roots (list xtt)
                
                :children-function (lambda (tree)
                                     (cond ((and (null (first tree))
                                                 (null (third tree)))
                                            nil)
                                           ((null (first tree))
                                            (list (list nil #\x nil) (third tree)))

                                           ((null (third tree))
                                            (list (first tree) (list nil #\x nil)))
                                           
                                           (t (list (first tree)
                                                    (third tree)))
                                           ))
                
                :print-function (lambda (node)
                                  (format nil "~A" (second node)))
                ))
|#

(defmethod set-children (tree layout)
  nil)

(defmethod set-children ((tree node) layout)
  (with-node-bindings (l _ r) tree
    (let ((lx (if (is-empty l)
                  (vector)
                l))
          (rx (if (is-empty r)
                  (vector)
                r)))
      (cond ((and (is-empty l)
                  (is-empty r))
             nil)
            (t 
             (case layout
               ((:left-right :right-left) (list rx lx))
               (t  (list lx rx))))
            ))))

(defmethod print-node (x keyfn)
  nil)

(defmethod print-node ((tree node) keyfn)
  (with-node-bindings (_ v) tree
    (with-standard-io-syntax
      (with-output-to-string (s)
        (princ (funcall keyfn v) s)
        ))))

(defmethod key-fn (item)
  item)

#+:LISPWORKS
(defmethod view-set ((s tree) &key (key #'key-fn) (layout :left-right))
  (capi:contain
   (make-instance 'capi:graph-pane
                  :layout-function layout
                  :roots (list s)

                  :children-function #'(lambda (node)
                                         (set-children node layout))
                  :print-function    #'(lambda (node)
                                         (print-node node key))
                  :action-callback (lambda (item intf)
                                     (declare (ignore intf))
                                     (inspect item))
                  )))

#|
;; examine effects of constructing a tree in pure ascending or descending order
(inspect (let ((xt (sets:empty))) (dotimes (ix 100) (setf xt (sets:add ix xt))) xt))
(view-set (let ((xt (sets:empty))) (dotimes (ix 100) (setf xt (sets:add ix xt))) xt))
(view-set (let ((xt (sets:empty))) (dotimes (ix 100) (setf xt (sets:add (- 99 ix) xt))) xt))
|#
;; -------------------------------------------------------------
#|
(defun tst (&optional (n 1000000))
  (let ((x (empty)))
    (loop repeat n do
          (setf x (add (random 1d0) x)))
    (cardinal x)))
(time (tst 1000000))

(defun tsth (&optional (n 1000000))
  (let ((x (make-hash-table)))
    (loop repeat n do
          (let ((v (random 1d0)))
            (setf (gethash v x) v)))
    ))
(time (tsth 1000000))
|#