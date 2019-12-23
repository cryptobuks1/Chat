;; reppy-actors.lisp -- Channels a'la Reppy's PCML
;;
;; DM/HMSC  01/00
;; DM/RAL   04/16 -- Major update and rewrite to accommodate SMP multiprocessing.
;;                   Corrected the implementation of wrap-abort, guard.
;;                   Major simplifications of event/abort handling
;;                   Unlike PCML, we don't get to automatically GC threads doing noting
;;                   but waiting on a signal that would never arrive. Rather, we have
;;                   to actively discard dead threads. And we do so by issuing an abort
;;                   against all other pending event firings after one of them succeeds.
;;                   If that abort calls DISCARD-CHANNEL, then all orphaned threads
;;                   known to that channel will be reclaimed.
;;
;; DM/RAL  08/16 -- Port to Linux/SBCL
;; DM/RAL  02/17 -- lock-free implementation
;; DM/RAL  11/17 -- Accommodate asynchronous Actors
;; DM/RAL  12/19 -- No longer specific to Actors, much streamlines,
;;                  full NACK implemented
;; -------------------------------------------------------------

(defpackage #:reppy-channels
  (:use #:common-lisp #:resource)
  (:nicknames #:rch)
  (:import-from #:useful-macros
   #:defmacro!
   #:if-let
   #:when-let
   #:foreach
   #:letrec
   #:nlet-tail
   #:capture-ans-or-exn
   #:recover-ans-or-exn
   #:dlambda
   #:dcase)
  (:import-from #:actors
   #:*timeout*
   #:timeout
   #:read-mbox-with-timeout)
  (:export
   ;; error conditions
   #:non-channel
   #:no-rendezvous
   #:*timeout*
   #:timeout

   ;; events and rendezvous
   #:spawn-process
   
   #:channel
   #:make-channel
   #:discard-channel
   #:reset-channel
   #:channel-valid-p
   
   #:recvevt
   #:sendevt
   #:alwaysevt
   #:failEvt
   #:abortEvt
   #:neverEvt
   #:timerEvt
   #:errorEvt
   #:timeoutEvt
   #:execEvt
   #:joinEvt
   #:keyEvt
   #:lineEvt
   #:sexpEvt

   #:wrap
   #:wrap-handler
   #:wrap-abort
   #:wrap-timeout
   #:wrap-error
   #:guard
   #:choose
   #:choose*

   #:recvEvt*
   #:sendEvt*
   #:abort-ch-evt
   #:wrap-notify-abort

   #:sync
   #:select
   #:select*
   #:send
   #:poke
   #:recv
   #:peek

   #:async
   #:asend
   #:arecv
   #:aselect
   #:aselect*
   #:had-rendezvous
   
   ;; other useful items
   #:once-ref

   #:with-channel
   #:with-channels

   #:on-sync
   #:wrapping
   ))

(in-package "REPPY-CHANNELS")

(declaim (optimize (speed 3) (safety 0) (float 0)))

;; ------------------------------------------------------
;; So here we have a system composed of three major subsystems...
;;   1. Threads
;;   2. Intercommunication between threads
;;   3. Composable events representing communication possibilities
;;
;; Threads are generated via SPAWN, and each thread attempting to
;; participate in a potential communication with other threads sets up
;; a tree of communication possibilities represented by an outer level
;; COMM-EVENT object. COM-EVENTS are composable objects. Combinators
;; for event objects can develop a tree of event possibilties.
;;
;; COMM-EVENTS are abstract possibilities for communications that
;; become instantiated with SYNC. Until then they remain abstract
;; composable possibilities. At SYNC, the tree of COMM-EVENTS is
;; reified into a list of lambda closures that represents the
;; rendezvous possibilities at the leaves of the event tree.
;;
;; Each closure represents the actions that may be carried out after a
;; rendezvous succeeds. The winning rendezvous closure will be asked
;; to remove all WITH-ABORT clauses leading back to the top of the
;; tree, and then to wrap its communicated data with the chain of WRAP
;; functions leading back to the top of the tree. All other
;; (non-successful) closures will be asked to perform the WITH-ABORT
;; closures leading back to the top of the tree in their respective
;; branches.
;;
;; In this way we can provide for cleanup on failed rendevouz
;; alternatives.
;;
;; To prevent multiple execution of WRAP-ABORT clauses a WRAP-ABORT
;; event keeps a once-only function pointer to the cleanup code. It
;; can return that function pointer only once, thereafter returning a
;; null value. The successful rendezvous branch can assure that none
;; of its own WRAP-ABORTS will get executed by preemptively reading
;; them out before the failed rendezvous branches have a chance to
;; attempt their own cleanup, some of which might possibly include the
;; same cade.
;;
;; To keep cleanup operations to a bounded cost on the winning thread,
;; any actual cleanup code is launched in its own thread.
;;
;; When a thread decides to instantiate a rendezvous with other
;; threads, a COMM object is produced and owned by that thread.  That
;; COMM object represents a proxy for the thread in all communication
;; activities.
;;
;; Threads communicate with each other via CHANNEL objects. A channel
;; object incorporates reader/writer queues and serves as a passive
;; data object joining two sides of a communcation rendezvous. No
;; thread owns a channel. And channels are shared between threads. But
;; channel integrity needs to be maintained while being operated upon
;; by any thread, through careful elision of interrupts and prevention
;; of the possibility for thread KILL while channel queues are being
;; updated.
;;
;; If a thread wishes to try any of several rendezvous possibilities,
;; its COMM object may end up on several channel reader/writer queues.
;; Channel reader/writer queues are implemented as lock-free.
;;
;; A rendezvous is normally a blocking operation awaiting the
;; simultaneous meeting between a reader and a writer on the same
;; channel. Either of the reader or the writer of a channel could
;; block. A channel represents the possibility of multiple writers and
;; multiple readers.
;;
;; In some cases the blocking of channel writers until readers become
;; active may be too punitive. For those cases we offer the extension
;; of non-blocking channel writes through channel POKE events which
;; always succeed immediately. But there is the possibility that its
;; write data may never be retrieved.
;;
;; To support the use of timers for timeout events, we also offer a
;; negating event combinator called Fail which causes a successful
;; rendezvous to behave as though it failed. In that case all higher
;; WRAP-ABORT handlers will be called, as well as those in other
;; branches of the event tree.
;;
;; With Lisp, we are not CML. Our threads are heavyweight by
;; comparison, and they are not automatically scavenged when their
;; parent thread (no such thing here) gets killed or dies.  The
;; situation is not ideal. So what to do?...
;;
;; [... this is where Custodians might help a bit... ]
;;
;; ---------------------------------------------------------------------

(defun join-thread (thread)
  #+:LISPWORKS (mp:process-join thread)
  #+:SBCL      (sb-thread:join-thread thread))

;; ---------------------------------------------
;; Timer Support

(defun make-timer (fn &rest args)
  #+:LISPWORKS (apply #'mp:make-timer fn args)
  #+:SBCL      (sb-ext:make-timer (lambda ()
                                    (apply fn args))))

(defun schedule-timer (timer dt &key absolute)
  #+:LISPWORKS
  (if absolute
      (mp:schedule-timer timer dt)
    (mp:schedule-timer-relative timer dt))

  #+:SBCL
  (sb-ext:schedule-timer timer dt :absolute absolute)) ;; fix me!!

(defun unschedule-timer (timer)
  #+:LISPWORKS (mp:unschedule-timer timer)
  #+:SBCL      (sb-ext:unschedule-timer timer))

;; -------------------------------------------------------
;; Reppy CML Style Channels and Events with Combinators

(defun spawn-process (fn &key args name)
  ;; For when you really want to spawn another thread
  (apply #'mp:process-run-function (symbol-name (gensym (or name "RCH:spawn-"))) nil
         fn args))

;; -----------------------------------------------------------

(define-condition no-rendezvous (error)
  ()
  (:report no-rendezvous))

(defun no-rendezvous (err stream)
  (declare (ignore err))
  (format stream "No event rendezvous"))

(defvar *no-rendezvous-token*  #()) ;; unique

;; ----------------------------------------------------------------------
;; Channel-Queue - a lockable FIFO
;;
;; In order to preserve fairness, we need FIFO ordering in the channel
;; readers / writers queues.

(defstruct (channel-queue
            (:constructor %make-channel-queue))
  (lock  (mp:make-lock))
  hd tl)

(defun make-channel-queue ()
  (let ((cell (list nil)))
    (%make-channel-queue
     :hd  cell
     :tl  cell)))

(defun channel-queue-send (q item)
  #F
  (declare (channel-queue q))
  (mp:with-lock ((channel-queue-lock q))
    (setf (the cons (channel-queue-tl q))
          (setf (cdr (the cons (channel-queue-tl q)))
                (list item)))))

(defun channel-queue-trim (q delete-pred)
  #F
  (declare (channel-queue q))
  (mp:with-lock ((channel-queue-lock q))
    (setf (cdr (the cons (channel-queue-hd q)))
          (delete-if delete-pred (cdr (the cons (channel-queue-hd q))))
          (channel-queue-tl q)
          (last (the cons (channel-queue-hd q))))))

(defun channel-queue-contents (q)
  ;; destructive readout
  #F
  (declare (channel-queue q))
  (mp:with-lock ((channel-queue-lock q))
    (prog1
        (shiftf (cdr (the cons (channel-queue-hd q))) nil)
      (setf (channel-queue-tl q) (channel-queue-hd q)))))

;; ----------------------------------------------------------------------
;; CHANNEL -- the object of a rendezvous between threads. Channel
;; objects are shared between threads, and so must be protected by a
;; lock when reading/writing them.

(defvar *comm-id*  0) ;; global ID counter

;; LW has a strong enough GC finalization protocol that it can deal
;; directly with core objects. No need for the handle indirection
;; and object-display seen in SBCL.
  
(defstruct (channel
            (:constructor %make-channel))
  (id       (sys:atomic-fixnum-incf *comm-id*)) ;; key for channel-refs
  (valid    (list t)) ;; i.e., not discarded, in active service
  (readers  (make-channel-queue))
  (writers  (make-channel-queue)))

(defmethod finalize ((ch channel))
  (release-resource ch)
  ch)

(defmethod finalize (obj)
  obj)

(defun make-channel ()
  (let ((ch (%make-channel)))
    (unless (get 'make-channel 'finalize)
      (setf (get 'make-channel 'finalize)
            (hcl:add-special-free-action 'finalize)))
    (hcl:flag-special-free-action ch)
    ch))

(defun channel-valid-p (ch)
  (car (channel-valid ch)))

(defmethod release-resource :before ((ch channel) &key &allow-other-keys)
  (discard-channel ch))

;; ------------------------------------------------
;; Channel-otable -- a sparse collection of channels that have been
;; allocated. This is like an object display with weak pointers and
;; is used to help GC automatically prod waiting threads on dead or
;; dying channels.
  
(defvar *channel-otable*  (make-hash-table
                           :weak-kind :value))

;; channel-refs enable us to unify the use of channels and indirect
;; refs. Pass a channel-ref to a thread if there is a possibility
;; that you want the GC to handle a stuck thread on a channel with
;; an ephemeral binding in a lexical context.
;;
;; Q: Should make-channel just always automatically create a
;; channel-ref and return that, instead of an actual channel?
;;
;; A: No, that probably goes too far. The weakness of the
;; channel-otable could have extant channels disappearing on us. As
;; long as there is at least one direct channel binding the channel
;; will not be discarded by the GC. There is a fine line to discern
;; between using direct channel bindings and channel-ref bindings.
;; Can we simplify this decision process?
  
(defstruct (channel-ref
            (:constructor %make-channel-ref))
  handle)
  
(defmethod make-channel-ref ((ch channel))
  (let ((key (channel-id ch)))
    (prog1
        (%make-channel-ref
         :handle  key)
      (setf (gethash key *channel-otable*)  ch))))

(defmethod make-channel-ref ((chref channel-ref))
  ;; in case user asks for a reference on what is already a reference
  chref)

(defmethod release-resource :after ((ch channel) &key &allow-other-keys)
  ;; release-resource is called by GC finalization
  (remhash (channel-id ch) *channel-otable*))

(define-condition non-channel ()
  ((arg  :accessor non-channel-arg
         :initarg :arg))
  (:report non-channel))

(defun non-channel (err stream)
  (format stream "Not a Channel: ~A" (non-channel-arg err)))

(defmethod reify-channel (ch)
  (error 'non-channel :arg ch))

(defmethod reify-channel ((ch channel))
  ch)

(defmethod reify-channel ((chref channel-ref))
  (reify-channel (gethash (channel-ref-handle chref) *channel-otable*)))
  
;; -----------------------------------------------------------------------
;; COMM-CELL -- one of these belongs to each thread attempting a
;; rendezvous.  These cells may become enqueued on pending
;; reader/writer queues in channels.  And with composable events the
;; cell may become enqueued on more than one channel, which any one of
;; them might successfully rendezvous.
;;
;; The first successful rendezvous claims the day. So on an SMP
;; processor we need to grab claims using atomic operators. We could
;; also use locks, but that seems too heavy handed.

(defstruct comm-cell
  ;; numerical sequence number for MCAS ordering
  (id          (sys:atomic-fixnum-incf *comm-id*))

  (lock        (mp:make-lock))
  
  ;; NIL if not yet performed, will contain the leaf BEV which fired
  ;; against this cell. I.e., in which leaf did the rendevouz occur?
  ;; Note: nowhere in this object is there any indication of what
  ;; counterparty was involved in the rendezvous. (Good for security.
  ;; Necessary?)

  ;; (performed   (ref nil))
  performed

  ;; needs-wait will be true if we are ever placed on a R/W queue and
  ;; need to wait for a rendezvous.
  (needs-wait t)

  ;; calling proc, some way to reach the thread that owns this object.
  (owner       (mp:make-mailbox))
  
  ;; all-evts - a list of all pending events for this comm
  all-evts

  ;; the comm data value
  (data  *no-rendezvous-token*)

  ;; the bev with a nack, if any
  nack

  ;; count of channels on which this object is currently enqueued
  ;; NOTE: this might show as zero, even if it had been placed on one
  ;; or more channels. SMP multithreading might have popped it off
  ;; those queues at any time.  The needs-wait slot will remain T.
  (refct       (list 0)))

;; ------------------

(declaim (inline comm< marked?))

(defun comm< (comm1 comm2)
  ;; ordering for comm objects, to avoid deadlocking when two of them
  ;; are being locked in sequence
  (declare (comm-cell comm1 comm2))
  (< (comm-cell-id comm1)
     (comm-cell-id comm2)))

;; ====================================================================
;; We are actually 20% faster using LOCKs, instead of MCAS

(defun mark (comm bev)
  ;; the comm might also be on other channels and might have been already marked
  ;; returns t if successfully marked, nil otherwise
  ;; interrupts should be disabled before calling this function
  ;; returns t if we marked, nil if not
  (declare (comm-cell comm))
  (mp:with-lock ((comm-cell-lock comm))
    (unless (comm-cell-performed comm)
      (setf (comm-cell-performed comm) bev))))

(defun marked? (comm)
  ;; return non-nil if already marked
  ;; interrupts should be disabled before calling this function
  (declare (comm-cell comm))
  (comm-cell-performed comm))

(defun do-with-lock2 (comm1 comm2 fn)
  (declare (comm-cell comm1 comm2))
    (if (comm< comm1 comm2)
        (mp:with-lock ((comm-cell-lock comm1))
          (mp:with-lock ((comm-cell-lock comm2))
            (funcall fn)))
      ;; else
      (mp:with-lock ((comm-cell-lock comm2))
        (mp:with-lock ((comm-cell-lock comm1))
          (funcall fn)))
      ))

(defmacro with-lock2 ((comm1 comm2) &body body)
  `(do-with-lock2 ,comm1 ,comm2 (lambda ()
                                  ,@body)))

(defun mark2 (comm1 bev1 comm2 bev2)
  ;; we know we won't succeed when (eq comm1 comm2)
  ;; must be called from within WITH-LOCK2
  (declare (comm-cell comm1 comm2))
  (unless (eq comm1 comm2)
    ;; to prevent deadlocks, always acquire in ascending ID order
    (unless (or (comm-cell-performed comm1)
                (comm-cell-performed comm2))
      (mp:with-interrupts-blocked
        (setf (comm-cell-performed comm1) bev1
              (comm-cell-performed comm2) bev2))
      )))

;; ====================================================================

(defun refct (comm)
  (declare (comm-cell comm))
  (car (comm-cell-refct comm)))

(defun incref (comm)
  (declare (comm-cell comm))
  (sys:atomic-fixnum-incf (car (comm-cell-refct comm))))

(defun decref (comm)
  (declare (comm-cell comm))
  (sys:atomic-fixnum-decf (car (comm-cell-refct comm))))

;; ----------------

(defun setup-comm (ev)
  (let ((comm  (make-comm-cell)))
    (declare (comm-cell comm))
    (setf (comm-cell-all-evts comm)
          (nreverse (get-leafs ev comm)))
    comm))

(defun failed-rendezvous (comm)
  (declare (comm-cell comm))
  (foreach #'do-abort (comm-cell-all-evts comm)))

(defun successful-rendezvous (comm bev)
  (declare (comm-cell comm))
  ;; kill off any wrap-aborts along the successful
  ;; rendezvous path
  (kill-aborts bev)
  ;; perform remaining wrap-aborts
  (failed-rendezvous comm)
  ;; perform any wraps along the rendezvous path
  (get-result bev))

;; ----------------
;; try to choose an unlikely set of message prefixes

(defun prod-owner (owner comm bev)
  (mp:mailbox-send owner :rendezvous-prod-{01786A6C-CD80-11E7-9B0D-985AEBDA9C2A} comm bev))

(defun cancel-rendezvous (owner comm)
  (mp:mailbox-send owner :rendezvous-cancel-{0774751E-CD80-11E7-9B0D-985AEBDA9C2A} comm))

(defun wait-for-comm-signaled (mbox)
  (dcase (read-mbox-with-timeout mbox)
    
    (:rendezvous-prod-{01786A6C-CD80-11E7-9B0D-985AEBDA9C2A} (comm bev)
     (declare (ignore comm))
     bev)

    (:rendezvous-cancel-{0774751E-CD80-11E7-9B0D-985AEBDA9C2A} (comm)
     (declare (ignore comm))
     nil)
    ))

(defun select-event (comm bev)
  (declare (comm-cell comm))
  (let* ((mbox   (comm-cell-owner comm))
         (wait   (comm-cell-needs-wait comm))
         (okay   mbox)) ;; mbox used as a sentinel for no-rendezvous
    (unwind-protect
        (let ((bev (or bev
                       (comm-cell-nack comm)
                       (when wait
                         (handler-case
                             (wait-for-comm-signaled mbox)
                           (timeout (c)
                             (if (mark comm t)
                                 (error c)
                               ;; else
                               (comm-cell-performed comm)))
                           ))
                       )))
          (cond ((bev-p bev)
                 (unless (eql *no-rendezvous-token* (comm-cell-data comm))
                   (setf okay t)
                   (successful-rendezvous comm bev)))

                (bev
                 (break) ;; when does this ever happen?
                 (setf okay bev))

                ((not wait) ;; async event
                 nil)

                (t
                 (break) ;; when does this ever happpen?
                 (error 'no-rendezvous))
                ))
      ;; unwind
      (when (eql okay mbox)
        (failed-rendezvous comm))
      )))

;; ------------------------------------

(defstruct comm-tuple
  ;; the structure of tuples stored in channel queues
  comm async bev data)

(defun enqueue-tuple (queue tup)
  ;; warning: simple-queue not thread-safe
  (declare (comm-tuple tup))
  (incref (comm-tuple-comm tup))
  (channel-queue-send queue tup)
  tup)

;; -----------------------------------------------------------------------
;; COMM-EVENT -- a basic component that represents every kind of
;; composable event. Each kind of event is distinguished by its
;; behavior (BEV).

(defun get-leafs (evt comm &optional leafs wlst alst)
  ;; leafs, wlst, and alst are accumulators that will hold a list of
  ;; leaf events, wrap clauses, and abort clauses, presenting their
  ;; accumulations to lower level event nodes in the event tree.
  ;;
  ;; These lists are presented to the leaf nodes to inform them of the
  ;; surrounding clauses along the path descending from the top of the
  ;; event tree to their location.
  ;;
  ;; On successful rendezvous a leaf event will be asked to remove the
  ;; wrap-abort clauses along its success path, and fold the layers of
  ;; wrap clauses around its data result.
  ;;
  ;; All unsuccessful leaf events will be asked to perform their
  ;; wrap-aborts.
  ;;
  ;; The lists become embedded in the leaf closures.
  ;;
  (if (functionp evt)  ;; embedded nulls might happen, c.f., choose
      (funcall evt comm leafs wlst alst)
    ;; else
    leafs))

;; -----------------------------------------------------------------------

(defun leaf-result (ans wlst)
  ;; apply the wrappers along the path to the top of the tree
  ;; - but do it in such a manner that any handlers in outer functions
  ;; also wrap the inner functions.
  (declare (list wlst))
  (labels ((iter (wlst)
             (if (consp wlst)
                 (destructuring-bind (fn . args) wlst
                   (if (consp fn) ;; handlers are provided as `(,fn)
                       (funcall (car fn) (lambda ()
                                           (iter args)))
                     ;; else
                     (funcall fn (iter args))
                     ))
               ;; else
               ans)))
    ;; WHen constructed wlst contains innermost functions at the head
    ;; of the list.
    (iter (reverse wlst))))

(defun leaf-kill-aborts (alst)
  ;;
  ;; Kill off any wrap-aborts along the path to the top of the tree.
  ;;
  ;; Calling a wrap-abort function asks it for its abort executive
  ;; function.  These are supposed to be once-only items, and so by
  ;; asking, we neutralize them for later queries.
  ;;
  (declare (list alst))
  (foreach #'funcall alst))

(defun leaf-abort (alst)
  (declare (list alst))
  ;; fire off all the wrap-abort clauses along the way back to the top
  ;; of the tree.
  ;;
  ;; Note: With Actors, it isn't safe to spawn these sub-jobs. Actors
  ;; demand single-thread semantics, and the code for the abort
  ;; clauses belongs to the Actor who created them. Hence the code may
  ;; be banging on Actor-local data, and so the Actor itself must
  ;; perform the abort clauses.
  (dolist (bevptr-once alst)
    (when-let (fn (funcall bevptr-once))
      (funcall fn))
    ))

;; BEVs = Behaviors
(defstruct bev
  poll result abort kill-aborts)

(defmacro make-leaf-behavior ((comm leafs wlst alst &key self)
                              &key ans poll kill-aborts result abort)
  ;; leaf events are the only ones capable of communicating across channels
  `(lambda (,comm ,leafs ,wlst ,alst)
     (declare (ignorable ,comm))
     ;; (check-comm-context ,comm)
     (letrec ((,self  (make-bev
                       :poll        (lambda ()
                                      ;; (check-comm-context ,comm)
                                      ,poll)
                       :result      (lambda ()
                                      ,(or result
                                           `(leaf-result ,ans ,wlst)))
                       :abort       (lambda ()
                                      ,(or abort
                                           `(leaf-abort ,alst)))
                       :kill-aborts (lambda ()
                                      ,(or kill-aborts
                                           `(leaf-kill-aborts ,alst)))
                       )))
             (cons ,self ,leafs)))) ;; leafs accumulate in reverse order of visit

#+:LISPWORKS
(editor:setup-indent "make-leaf-behavior" 1)

;; -----------------------------------------------------------------------
;; dlambda functions

(defmethod poll ((bev bev))
  ;; every leaf node has a :poll routine
  (funcall (bev-poll bev)))

(defmethod get-result ((bev bev))
  ;; every leaf node has a :result routine
  (funcall (bev-result bev)))

(defmethod do-abort ((bev bev))
  ;; every leaf node has a :abort routine
  (funcall (bev-abort bev)))

(defmethod kill-aborts ((bev bev))
  ;; every leaf node has a :kill-aborts routine
  (funcall (bev-kill-aborts bev)))

;; -----------------------------------------------------------------------
;; There are two dimensions of SMP multiple access here...  The first
;; is against the channel, and the second is against comm-cel objects.
;; Channels are shared among threads and comm-cells are shared among
;; channels.
;;
;; We use a multiple-CAS (MCAS) protocol on the comm-cells to allow
;; unrestricted and paired marking attempts by all threads. A
;; successful pair marking connotes a rendezvous.
;;
;; And for channel objects, what are shared are their reader/writer
;; queues. Those queues implement a fast-spin exclusive access control
;; of their own.
;;
;; But to get along properly in a shared SMP environment, each thread
;; must announce its intentions during polling by posting a reader or
;; writer queue entry before actually polling the opposite queue for
;; matching rendezvous events.
;;
;; Note that because of our MCAS marking protocol, simultaneous
;; send/recv on a channel, in either order, works okay, i.e., we do
;; not self-trigger, except in the case of recv after poke. Hence we
;; behave as would be desired.
;;

(defun find-eligible-tuple (queue my-comm my-bev)
  ;; Scan a queue for an eligbible tuple and discard marked tuples
  ;; from the queue. An eligible tuple may become marked from
  ;; eligible-p. This version avoids consing.
  (let (ans)
    (flet
        ((try-rendezvous (tup)
           (declare (comm-tuple tup))
           (let ((other-comm (comm-tuple-comm tup))
                 (other-bev  (comm-tuple-bev tup))
                 (data       (comm-tuple-data tup)))
             (unless ans
               (with-lock2 (my-comm other-comm)
                 (when (mark2 my-comm my-bev other-comm other-bev)
                   (cond ((eql data *no-rendezvous-token*)
                          (setf (comm-cell-nack my-comm) my-bev  ;; make note of nack
                                (comm-cell-performed my-comm) nil)) ;; unmark myself
                         (t
                          (setf ans tup))
                         ))))
             (when (marked? other-comm)
               (decref other-comm)) ;; returns non-nil
             )))
      (channel-queue-trim queue #'try-rendezvous)
      ans)))

(defun do-polling (ch queue my-comm my-bev rendezvous-fn blocking-fn)
  (declare (channel ch)
           (function rendezvous-fn blocking-fn))
  ;; such strong similarities between reader & writer polling that
  ;; they should share a common core code
  (when (channel-valid-p ch) ;; return nil if discarded channel
    (let ((blkval (funcall blocking-fn)))
      (if-let (tup (find-eligible-tuple queue my-comm my-bev))
          (locally
            (declare (comm-tuple tup))
            (with-accessors ((other-comm  comm-tuple-comm)
                             (other-async comm-tuple-async)
                             (other-bev   comm-tuple-bev)) tup
              (funcall rendezvous-fn tup)
              (unless other-async
                (prod-owner (comm-cell-owner other-comm) other-comm other-bev))
              my-bev)) ;; indicate successful rendezvous
        
        ;; else - no rendezvous during poll
        ;; indicate need to block waiting for rendezvous
        blkval))))
      
;; -----------------------------------------------------------------

(defun sendEvt (ch data &key async)
  (make-leaf-behavior (wcomm leafs wlst alst :self me)
    ;; SendEvt behavior -- scan the channel pending readers to see if
    ;; we can rendezvous immediately. If not, then enqueue us on the
    ;; pending writers for the channel.
    :ans   (comm-cell-data wcomm)
    :poll  (progn
             (when async
               (setf (comm-cell-needs-wait wcomm) nil))
             (when-let (ch (reify-channel ch))
               (locally
                 (declare (channel ch)
                          (comm-cell wcomm))
                 
                 (labels ((rendezvous (tup)
                            (declare (comm-tuple tup))
                            (with-accessors ((rcomm      comm-tuple-comm)
                                             (other-data comm-tuple-data)) tup
                              (declare (comm-cell rcomm))
                              (setf (comm-cell-data rcomm) data
                                    (comm-cell-data wcomm) other-data)))
                          
                          (blocking ()
                            ;; -----------------------------------------------
                            ;; When no pending reads, enqueue the write.
                            ;; Return nil to indicate we did not rendezvous.
                            (enqueue-tuple (channel-writers ch)
                                           (make-comm-tuple
                                            :comm  wcomm
                                            :async async
                                            :bev   me
                                            :data  data))
                            nil))
                   
                   (declare (dynamic-extent #'rendezvous #'blocking))
                   
                   (do-polling ch (channel-readers ch) wcomm me
                               #'rendezvous #'blocking)
                   ))))
    ))

;; -----------------------------------------------------------------

(defun recvEvt (ch &key async abort)
  (make-leaf-behavior (rcomm leafs wlst alst :self me)
    ;; recvEvt behavior -- scan the channel pending writers to see if
    ;; we can rendezvous immediately. If not, then enqueue us on the
    ;; channel pending readers.
    :ans  (comm-cell-data rcomm)
    :poll (progn
            (when async
              (setf (comm-cell-needs-wait rcomm) nil))
            (when-let (ch (reify-channel ch))
              (locally
                (declare (channel ch)
                         (comm-cell rcomm))
                
                (labels ((rendezvous (tup)
                           (declare (comm-tuple tup))
                           (with-accessors ((data  comm-tuple-data)
                                            (wcomm comm-tuple-comm)) tup
                             (declare (comm-cell rcomm))
                             (setf (comm-cell-data rcomm) data
                                   (comm-cell-data wcomm) abort)))
                         
                         (blocking ()
                           (unless async
                             (enqueue-tuple (channel-readers ch)
                                            (make-comm-tuple
                                             :comm  rcomm
                                             :async async
                                             :bev   me
                                             :data  abort)))
                           nil))  ;; indicate failure to rendezvous
                  
                  (declare (dynamic-extent #'rendezvous #'blocking))
                  
                  (do-polling ch (channel-writers ch) rcomm me
                              #'rendezvous #'blocking)
                  ))))
    ))

;; -----------------------------------------------------------------

(defun alwaysEvt (data)
  (make-leaf-behavior (comm leafs wlst alst :self me)
    ;; alwaysEvt behavior -- always successfully rendezvous if we
    ;; haven't already rendevoused elsewhere.
    :ans  data
    :poll (and (mark comm me)
               (setf (comm-cell-data comm) data)
               me)
    ;; The comm might also be on other channels and might have been
    ;; marked. Either way, we successfully polled but allow other mark
    ;; to take effect
    ))

(defun neverEvt ()
  ;; an event which serves to create a NIL COMM-EVENT object
  ;; .. useful as a nil-stub in a situation like this:
  ;;
  ;;       (choose (recvEvt ch)
  ;;               (if timeout
  ;;                   (timeoutEvt timeout)
  ;;                 (neverEvt)))
  ;;
  ;; We need this stub in order to perform the wrap-aborts. It will
  ;; never be chosen, and need never offer any result, but it holds
  ;; a list of wrap-aborts.
  ;;
  (make-leaf-behavior (comm leafs wlst alst :self me)
    :poll (progn
            (setf (comm-cell-needs-wait comm) t)
            nil)))

(defun execEvt (fn &rest args)
  ;; a computed result, but defers computation as late as possible so
  ;; that earlier events might rendezvous first and never need the
  ;; computation
  (let ((data nil))
    (make-leaf-behavior (comm leafs wlst alst :self me)
      :ans  data
      :poll (when (mark comm me)
              (setf (comm-cell-data comm)
                    (setf data (apply fn args)))
              me)
      )))

;; -----------------------------------------------------
;; Reppy Combinators
;;

(defun get-list-of-leafs (comm evs leafs wlst alst)
  ;; result is returned in reverse order. But so are the surrounding
  ;; elements. To get CHOOSE* to behave properly you need to reverse the
  ;; order of the grand list before polling. It won't do any good to
  ;; perform that reversal here...
  (reduce #'(lambda (leafs ev)
              (get-leafs ev comm leafs wlst alst))
          evs
          :initial-value leafs))


(defun choose* (&rest evs)
  ;; an event that provides for deterministic ordering of alternative
  ;; event rendezvous (c.f., CHOOSE). Only one event can rendezvous.
  ;;
  ;; While it is possible that none can immediately rendezvous, and we
  ;; may be placed on a pending reader/writer queue, the ordering
  ;; allows for early rendezvous via first scan polling. Ordering may
  ;; be preferential here.
  ;; (assert (every #'comm-event-p evs))
  (lambda (comm leafs wlst alst)
    (get-list-of-leafs comm evs
                       leafs wlst alst)))

;; --------------------------------------------------

(defun scramble-list (lst)
  #F
  (declare (list lst))
  (let ((rnd  (random (ash 1 (length lst))))
        hd tl
        (ix 0))
    (declare (integer rnd)
             (list hd tl)
             (fixnum ix))
    (dolist (item lst (nconc hd tl))
      (if (logbitp ix rnd)
          (push item hd)
        (push item tl))
      (incf ix))
    ))


(defun choose (&rest evs)
  ;; a CHOOSE event provides a nondeterministic ordering of
  ;; alternative event rendezvous (c.f. choose*). Only one event can
  ;; rendezvous.
  ;;
  ;; While it is possible that none can immediately rendezvous, and we
  ;; may be placed on a pending reader/writer queue, the ordering
  ;; allows for early rendezvous via first scan polling. But ordering
  ;; is random here, giving no particular preference to any of the
  ;; alternative events.
  ;; (assert (every #'comm-event-p evs))
  (lambda (comm leafs wlst alst)
    (get-list-of-leafs comm
                       (scramble-list evs)
                       leafs wlst alst)))

;; --------------------------------------------------

;; destructive read cell
(defun once-ref (&rest val-as-cons)
  (lambda ()
    (sys:atomic-exchange (car val-as-cons) nil)))

;; --------------------------------------------------

(defun wrap-abort (ev fn)
  ;; fn should be a thunk (function of no args). Funciton will be
  ;; called only if the wrapped event fails to rendezvous.
  (lambda (comm leafs wlst alst)
    (let ((bev  (once-ref fn))) ;; funcalling bev returns fn, but only the first time.
      ;; why the once-ref indirection? We need to break cycles in
      ;; the abort graph, where more than one leaf might have a
      ;; given abort clause along the path to the root of the event
      ;; tree. We only want the abort clause to fire once.
      (get-leafs ev comm leafs wlst (cons bev alst)))))

;; --------------------------------------------------

(defun failEvt (ev)
  ;; a failEvt ensures that if its wrapped event rendezvous, the
  ;; outer layers of wrap-abort will not be cleared. The result of the
  ;; wrapped rendezvous is returned.
  ;;
  ;; So the effect of an unwind-protect can be had by code like the
  ;; following:
  ;;
  ;;     (wrap-abort (fail (recvEvt ch))
  ;;       (lambda ()
  ;;        (perform-cleanup))
  ;;
  (lambda (comm leafs wlst alst)
    (declare (ignore alst))
    (get-leafs ev comm leafs wlst nil)))

(defun abortEvt (&optional val)
  (failEvt (alwaysEvt val)))


;; ------------------------------------------------------------------
;; For Nack'able events, we use two channels: one for data transfer,
;; the other for sending an abort notice.
;; The abort channel will be poked, with itself as value,
;; if the send/recv fail to rendezvous, to inform the other side.
;; These should be used in opposing pairs, one on each side.

(defun abort-ch-evt (cha)
  ;; sense nack feedback and generate a failed rendezvous
  (failEvt (recvEvt cha)))

(defun wrap-notify-abort (ch ev)
  ;; perform nack feedback on aborted rendezvous
  (wrap-abort ev
              (lambda ()
                (sync (choose* (recvEvt ch
                                        :abort *no-rendezvous-token*)
                               (sendEvt ch *no-rendezvous-token*
                                        :async t)
                               )))
              ))

(defun sendEvt* (ch val &key async)
  ;; a version of sendEvt with nack feedback
  (wrap-notify-abort ch 
                     (sendEvt ch val :async async)))

(defun recvEvt* (ch &key async)
  ;; a version of recvEvt with nack feedback
  (wrap-notify-abort ch
                     (recvEvt ch :async async)))

;; --------------------------------------------------

(defun wrap (ev fn)
  ;; fn should expect one argument.  The function only gets called on
  ;; the result of a rendezvous of its enclosed event, replacing the
  ;; event value with the result of its execution.
  ;;
  ;; If the rendezvous fails, then the function is not called.
  ;;
  ;; WRAP wraps an event to become another outer event.
  ;;
  ;; ... this is rather like an :AROUND method on the rendezvous
  ;; result. The returned value from a wrapped rendezvous is the
  ;; result produced by the function fn. If this wrapped event is not
  ;; chosen, the function will not be asked to perform.
  ;;
  (lambda (comm leafs wlst alst)
    (get-leafs ev comm leafs (cons fn wlst) alst)))

(defun wrap-handler (ev fn)
  ;; Wrapped handlers provide for error handling of rest of wrapper
  ;; functions leading to the BEV.
  ;;
  ;; A wrapped handler is a function expecting another function.
  ;; E.g.,
  ;;         (wrap-handler ev
  ;;                 (lambda (fn)
  ;;                     (handler-case
  ;;                        (funcall fn)
  ;;                      (error ()
  ;;                         (....))
  ;;                   ))
  ;;
  (lambda (comm leafs wlst alst)
    (get-leafs ev comm leafs (cons `(,fn) wlst) alst)))

;; --------------------------------------------------

(defun guard (fn)
  ;; a guarded function must return another COMM-EVENT
  ;; ... rather like an around handler on embedded events
  ;; The fn is only executed if this event is chosen.
  (lambda (comm leafs wlst alst)
    (get-leafs (funcall fn) comm leafs wlst alst)))

;; --------------------------------------------------
;; user level event composition

(defun sync (ev)
  ;; reify abstract events to produce a rendezvous
  (let* ((comm (setup-comm ev))
         (bev  (find-if #'poll (comm-cell-all-evts comm))))
    (select-event comm bev)))

(defmacro on-sync (&body body)
  `(guard
    (lambda ()
      ,@body)))

;; ---------------------------------------------------------------------------

(defun wrapping (evt &key on-rendezvous on-abort)
  (let ((wevt  (if on-rendezvous
                   (wrap evt
                         on-rendezvous)
                 evt)))
    (if on-abort
        (wrap-abort wevt
                    on-abort)
      wevt)))

;; ---------------------------------------------------------

(defun recv (ch)
  (sync (recvEvt ch)))

(defun send (ch item)
  (sync (sendEvt ch item)))

;; -------------------------------------------

(defun poke (ch item)
  ;; send the item, but don't wait for a matching recv
  (sync (sendEvt ch item :async t)))

(defun peek (ch)
  (sync (recvEvt ch :async t)))

;; -----------------------------------------

(defun select (&rest evs)
  (sync (apply 'choose evs)))

(defun select* (&rest evs)
  (sync (apply 'choose* evs)))

;; -----------------------------------------

(defmethod ac:send ((ch channel) &rest message)
  ;; non-blocking semantics for Actor send
  (poke ch message))

;; --------------------------------------------------

(defun timerEvt (dt &key absolute)
  ;; an event that rendezvous with a timer
  ;; dt will be a relative time unless :absolute is T
  (check-type dt (or null
                     (real 0.0)))
  (cond ((null dt) ;; no time indicated -- just form a nop event
         (neverEvt))
        
        ((not (plusp dt))
         (alwaysEvt t)) ;; should already have fired
        
        (t ;; anything else is a real timer rendezvous
           (guard (lambda ()
                    (let* ((ch     (make-channel))
                           (timer  (make-timer #'mp:funcall-async #'poke ch t)))
                      (schedule-timer timer dt :absolute absolute)
                      (wrap-abort (recvEvt ch)
                                  (lambda ()
                                    (unschedule-timer timer)))
                      ))))
        ))

;; ----------------------------------------------------------------------------------
;; Events that could generate errors if chosen

(defun wrap-error (ev errfn)
  ;; An event that fires an error if successful rendezvos. It also
  ;; acts like a failed rendezvous. Errfn should be prepared to accept
  ;; one argument, which is the result of the ev rendezvous.
  (failEvt
   (wrap ev
         (lambda (v)
           (error (funcall errfn v)))
         )))

(defun errorEvt (errfn)
  ;; An event that always fails with an error. Doing it this way,
  ;; instead of just presenting an immediate error allows the error to
  ;; be bypassed if this event is never chosen. The error in the
  ;; wrapped function only occurs on successful rendezvous with this
  ;; event.
  (wrap-error (alwaysEvt nil)
              errfn))

(defun timeoutEvt (dt)
  ;; an event that produces a timeout error
  (wrap-error (timerEvt dt)
              (lambda (arg)
                (declare (ignore arg))
                'timeout)))

(defun wrap-timeout (dt ev)
  (choose* ev
           (timeoutEvt dt)))

;; ----------------------------------------------------------------------------

(defun discard-channel (ch)
  (when (sys:compare-and-swap (car (channel-valid ch)) t nil) ;; if was valid?
    (labels
        ((prod (q)
           (dolist (tup (channel-queue-contents q))
             (let ((comm  (comm-tuple-comm tup))
                   (async (comm-tuple-async tup)))
               (decref comm)
               (when (and (zerop (refct comm))   ;; not on any other queues
                          (mark comm t)          ;; hasn't already rendezvous
                          (not async))           ;; not an async event
                 ;; since there should be no contention for the comm
                 ;; object, (i.e., the channel has been discarded and
                 ;; so no possibility of rendezvous) we use the mark
                 ;; operation merely to check whether or not it has
                 ;; already rendezvousd.
                 (cancel-rendezvous (comm-cell-owner comm) comm)) ;; prod with rendezvous failure
               ))))
      (prod (channel-readers ch))
      (prod (channel-writers ch))
      )))

(defun reset-channel (ch)
  (discard-channel ch)
  (sys:compare-and-swap (car (channel-valid ch)) nil t))

;; ---------------------------------------------------------
;; Safe access of a channel shared through argument passing...
;;
;; When a channel is sent to another thread it is possible that the
;; channel will become abandoned by the sender, leaving the thread to
;; fend for itself. And we want to be able to scavenge abandoned
;; threads with GC finalization on the abandoned channel. So the only
;; way to have that work is by assuring that no stray references to a
;; channel are left lying around.
;;
;; By passing a once-only ref to a shared channel, we both allow for
;; the GC scavenging (via once-ref), and by using these safe accessors
;; on the shared channel, we gracefully manage the possibility that
;; the channel will have been abandoned and we should not pay for an
;; error of type no-rendezvous.
;;
;; However, if the thread needs to know that the channel was
;; abandoned, as with an RPC with transactional roll-back, then you
;; should not call these safe-xxx routines, and you should manage the
;; errors for yourself.
;;
;; By curiosity of the implementation, I found that simply passing a
;; (list ch) indirect reference is insufficient to enable GC
;; scavenging when combined with handler-case or ignore-errors.
;; Instead, the indirect reference needs to be something not easily
;; transformed into stack-local references by the compiler optimizer.
;; And to achieve that we make use of the once-ref functional closure
;; mechanism shown here.
;;
;; Note that to achieve GC scavenging, a reference to the channel must
;; be used. You cannot allow the thread function to capture the channel
;; from its lexical environment as in:
;;
;;   (let ((ch (make-channel)))
;;       (spawn (lambda ()
;;                 (do-something-with ch)))
;;    ... )
;;
;; The reason for this is that the lexical binding in the functional
;; closure remains, preventing GC scavenging. Instead, you must pass
;; an indirect reference to the channel, either through argument
;; passing, or by a lexical capture. And that reference must be a
;; self-erasing version (or be manually erased) so that it removes any
;; vestigial channel reference after final access.

;; The following functions really only work as intended when called
;; from non-Actor threads. An Actor will perform the sync immediately
;; and continue in its body code. The eventual sync rendezvous will
;; lead to a callback being performed by the original Actor. But by
;; that time, the handler-case will have completed and is no longer
;; surrouding the callback functon in the Actor.
;;
;; At the same time, Actor based rendezvous failures don't generate
;; errors unless the Actor-provided fail handler does so.

#|
(defun safe-poke (ch val)
  (handler-case
      ;; we might get a no-rendevous error if the channel has been
      ;; scavenged by the GC as a result of sender getting diverted
      ;; with another rendevous instead of this one.
      (poke ch val)
    (no-rendezvous ())))

(defun safe-peek (ch)
  ;; this one probably isn't needed, but there is an implicit race
  ;; condition in not doing so
  (handler-case
      (peek ch)
    (no-rendezvous ())))

(defun safe-send (ch item)
  (handler-case
      (send ch item)
    (no-rendezvous ())))

(defun safe-recv (ch)
  (handler-case
      (recv ch)
    (no-rendezvous ())))
|#

;; ---------------------------------------------------------

(defun joinEvt (thread)
  ;; an event that waits until thread finishes, dies, is terminated,
  ;; or is already dead
  (execEvt #'join-thread thread))

(defun flush-input (stream)
  (do ()
      ((null (read-char-no-hang stream nil nil)))
    ))

(defun keyEvt (&key flush (stream *standard-input*))
  ;; an event that waits on a keyboard character
  (execEvt (lambda ()
             (when flush
               (flush-input stream))
             (read-char stream))))

(defun lineEvt (&key flush (stream *standard-input*))
  ;; an event that waits on a line of input from the keyboard
  (execEvt (lambda ()
             (when flush
               (flush-input stream))
             (read-line stream))))

(defun sexpEvt (&key flush (stream *standard-input*) read-eval)
  ;; an event that waits for a SEXP of input from the keyboard
  (execEvt (lambda ()
             (when flush
               (flush-input stream))
             (let ((*read-eval* read-eval))
               (read stream)))
           ))

;; ---------------------------------------------------------

(defmacro with-channel (ch &body body)
  `(let ((,ch (make-channel)))
     (unwind-protect
         (progn
           ,@body)
       (release-resource ,ch))))

(defmacro with-channels (chlist &body body)
  `(let ,(mapcar #1`(,a1  (make-channel)) chlist)
     (unwind-protect
         (progn
           ,@body)
       (foreach #'release-resource (list ,@chlist))
       )))

;; ---------------------------------------------------------
