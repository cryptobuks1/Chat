;;; -*- Mode: LISP; Syntax: COMMON-LISP -*-
;;;; chat.asd -- ASDF File for Chat protocol simulator

#|
Copyright (c) 2019 Stegos AG

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

(defsystem "chat-btree"
  :description "Chat: Chat Sessions in the Blockchain"
  :version     "1.0.3"
  :author      "D.McClain <dbm@stegos.com>"
  :license     "Copyright (c) 2019 by Stegos, A.G. MIT License."
  :depends-on (ironclad
               actors
               core-crypto
               lisp-object-encoder
               useful-macros)
  :in-order-to ((test-op (test-op "chat-test")))
  :components ((:module package
                        :pathname "./btree/"
                        :components ((:file "package")))
               (:module source
                        :depends-on (package)
                        :pathname "./btree/"
                        :serial t
                        :components ((:file "utxos")
                                     (:file "blockchain-sim")
                                     (:file "p2p")
                                     (:file "group-chat-owner")
                                     (:file "wallet-sim")
                                     (:file "run-sim")
                                     ))))

