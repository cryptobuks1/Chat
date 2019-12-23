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

#|
(defpackage #:dlam
  (:use #:common-lisp)
  (:export
   #:dlam-fun
   #:dlam-keys
   #:dlam-fns
   #:dlam-def
   #:dlambda
   #:dcase
   #:replace-handlers
   #:replace-handler
   ))
|#

(in-package #:dlam)

;; ----------------------------------------------------------------------

#| |#
(um:defmacro! dlambda (&rest ds)
  `(lambda (&rest ,g!args)
     (let ((,g!tail (cdr ,g!args)))
       (case (car ,g!args)
         ,@(mapcar
            (lambda (d)
              `(,(if (eq t (car d))
                     t
                   (list (car d))
                   )
                (apply (lambda ,@(cdr d))
                       ,(if (eq t (car d))
                            g!args
                          g!tail)) ))
            ds)))))

(defmacro dcase (args &rest clauses)
  `(apply (dlambda
            ,@clauses)
          ,args))

#+:LISPWORKS
(editor:setup-indent "dcase" 1)

#| |#

;; ----------------------------------------------------------------------
#|
;; equiv to #F
;; (declaim  (OPTIMIZE (SPEED 3) #|(SAFETY 0)|# #+:LISPWORKS (FLOAT 0)))
;; (declaim  (OPTIMIZE (SPEED 3) #+:LISPWORKS (FLOAT 0)))

(defun make-dlambda-dispatcher (fns def)
  (lambda (&rest args)
    (apply (getf fns (car args) def) args)))

(defun dlam-no-default (&rest args)
  (declare (ignore args))
  (error "No default action specified"))

(defmacro dlambda (&rest clauses)
  (let* ((def   ''dlam-no-default)
         (dummy (gensym))
         (lams  (mapcan (lambda (clause)
                          (and dummy
                               (destructuring-bind (key args . body) clause
                                 (if (eql t key)
                                     (setf def `(lambda ,args ,@body)
                                           dummy nil)
                                   `(',key (lambda ,(cons dummy args) ,@body)))
                                 )))
                        clauses)))
    `(make-dlambda-dispatcher (list ,@lams) ,def)))

(defmacro dcase (args &rest clauses)
  ;; make a once-only cached dlambda in case the dcase is in a loop
  ;; this speeds things up, and also preserves internal state between invocations
  `(apply (dlambda ,@clauses) ,args))

#+:LISPWORKS
(editor:setup-indent "DCASE" 1 nil nil 'flet)
#+:LISPWORKS
(editor:setup-indent "DLAMBDA" 0 nil nil 'flet)

|#
;; -----------------------------------------------------------------

#|
(let ((fn  (dlambda
            (:one () 1)
            (:two () 2)
            (t  (&rest args) :What?))))
  ;; (inspect fn)
  (funcall fn :zero))

(dcase '(:three)
  (:one () 1)
  (:two () 2)
  (t (&rest args) :Huh?))

(loop for ix in '(:one :two :three :four :five) do
      (print
       (funcall (let ((ct 0))
                  (lambda (&rest args)
                    (incf ct)
                    (apply (dlambda
                             (:one () 1)
                             (:two () 2)
                             (:five () 5)
                             (t (&rest args)
                                (declare (ignore args))
                                :Huh?
                                (print ct)))
                           args)))
                ix)))
  
         
 |#
