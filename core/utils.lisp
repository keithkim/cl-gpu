;;; -*- mode: Lisp; Syntax: Common-Lisp; -*-
;;;
;;; Copyright (c) 2010 by Alexander Gavrilov.
;;;
;;; See LICENCE for details.

(in-package :cl-gpu)

#+ccl
(def function double-offset-fixup (ivector)
  (case (ccl::typecode ivector)
    ((#.target::subtag-double-float-vector
      #+64-bit-target #.target::subtag-s64-vector
      #+64-bit-target #.target::subtag-u64-vector
      #+64-bit-target #.target::subtag-fixnum-vector)
     #.(- target::misc-dfloat-offset
          target::misc-data-offset))
    (otherwise 0)))

#+ccl
(def function array-ivector-range (arr)
  (multiple-value-bind (ivector ofs)
      (ccl::array-data-and-offset arr)
    (let* ((typecode (ccl::typecode ivector))
           (fixup (double-offset-fixup ivector))
           (base (+ fixup (ccl::subtag-bytes typecode ofs)))
           (size (ccl::subtag-bytes typecode (array-total-size arr))))
      (values ivector base size))))

(def (function e) write-array-bytes (array stream)
  "Write the contents of the array to a binary stream."
  #+ecl (write-sequence (ext:array-raw-data array) stream)
  #+ccl (multiple-value-bind (ivector base size)
            (array-ivector-range array)
          (ccl:stream-write-ivector stream ivector base size))
  #-(or ecl ccl) (error "Not implemented"))

(def (function e) read-array-bytes (array stream)
  "Restore the contents of the array from a binary stream."
  #+ecl (read-sequence (ext:array-raw-data array) stream)
  #+ccl (multiple-value-bind (ivector base size)
            (array-ivector-range array)
          (ccl:stream-read-ivector stream ivector base size))
  #-(or ecl ccl) (error "Not implemented"))

(def function array-type-tag (array)
  (ecase (array-element-type array)
    (single-float #x46525241)
    (double-float #x44525241)))

(def function array-type-by-tag (tag)
  (ecase tag
    (#x46525241 'single-float)
    (#x44525241 'double-float)))

(def (function e) write-array (array stream)
  "Store the array to a binary stream with meta-data."
  (let* ((dims (list* (array-type-tag array)
                      (array-rank array)
                      (array-dimensions array)))
         (header (make-array (length dims)
                             :element-type '(unsigned-byte 32)
                             :initial-contents dims)))
    (declare (dynamic-extent dims header))
    (write-array-bytes header stream)
    (write-array-bytes array stream)))

(def (function e) read-array (array stream &key allocate)
  "Restore data written using write-array."
  (let ((base-hdr (make-array 2 :element-type '(unsigned-byte 32))))
    (declare (dynamic-extent base-hdr))
    (read-array-bytes base-hdr stream)
    (let ((type (array-type-by-tag (aref base-hdr 0)))
          (dims (make-array (aref base-hdr 1)
                            :element-type '(unsigned-byte 32))))
      (declare (dynamic-extent dims))
      (read-array-bytes dims stream)
      (if array
          (let ((adims (array-dimensions array)))
            (unless (equal (upgraded-array-element-type type)
                           (array-element-type array))
              (error "Type mismatch: array ~A, file ~A"
                     (array-element-type array) type))
            (unless (and (eql (length dims) (length adims))
                         (every #'eql adims dims))
              (error "Dimension mismatch: array ~A, file ~A" adims dims)))
          (progn
            (unless allocate
              (cerror "allocate" "Array is nil in read-array"))
            (setf array (make-array (coerce dims 'list)
                                    :element-type type))))
      (read-array-bytes array stream)
      array)))

(def (function e) copy-array (array)
  "Create a new array with the same contents."
  (let ((dims (array-dimensions array)))
    (adjust-array
     (make-array dims
                 :element-type (array-element-type array)
                 :displaced-to array)
     dims)))

(def function %portable-copy-array-data (src-array src-ofs dest-array dest-ofs count)
  (declare (type fixnum src-ofs dest-ofs count)
           (type array src-array dest-array))
  (if (and (eq dest-array src-array) (> dest-ofs src-ofs))
      (let ((dest-base (+ dest-ofs count -1))
            (src-base (+ src-ofs count -1)))
        (declare (type fixnum dest-base src-base))
        (dotimes (i count)
          (declare (fixnum i))
          (setf (row-major-aref dest-array (- dest-base i))
                (row-major-aref src-array (- src-base i)))))
      (dotimes (i count)
        (declare (fixnum i))
        (setf (row-major-aref dest-array (+ dest-ofs i))
              (row-major-aref src-array (+ src-ofs i))))))

(def function %copy-array-data (src-array src-ofs dest-array dest-ofs count)
  (declare (type fixnum src-ofs dest-ofs count)
           (type array src-array dest-array))
  #+ccl
  (bind (((:values src-vec src-delta)   (ccl::array-data-and-offset src-array))
         ((:values dest-vec dest-delta) (ccl::array-data-and-offset dest-array))
         (src-index (+ src-delta src-ofs))
         (dest-index (+ dest-delta dest-ofs)))
    (cond
      ;; Reference vector
      ((and (ccl::gvectorp src-vec) (ccl::gvectorp dest-vec))
       (ccl::%copy-gvector-to-gvector src-vec src-index dest-vec dest-index count))
      ;; Unaligned bit move
      ((and (or (bit-vector-p src-vec) (bit-vector-p dest-vec))
            (or (logtest src-index 7) (logtest dest-index 7) (logtest count 7)))
       (%portable-copy-array-data src-vec src-index dest-vec dest-index count))
      ;; Raw data vector
      ((and (ccl::ivectorp src-vec) (ccl::ivectorp dest-vec))
       (let* ((type (ccl::typecode dest-vec))
              (fixup (double-offset-fixup dest-vec))
              (src-byte (+ fixup (ccl::subtag-bytes type src-index)))
              (dest-byte (+ fixup (ccl::subtag-bytes type dest-index)))
              (byte-count (ccl::subtag-bytes type count)))
         (assert (eql type (ccl::typecode src-vec)))
         (ccl::%copy-ivector-to-ivector src-vec src-byte dest-vec dest-byte byte-count)))
      ;; Unknown
      (t (error "Array type mismatch"))))
  #+ecl
  (if (and (eq dest-array src-array) (> dest-ofs src-ofs))
      (%portable-copy-array-data src-array src-ofs dest-array dest-ofs count)
      (ffi:c-inline
          (dest-array dest-ofs src-array src-ofs count)
          (:object :int :object :int :int) :void
        "ecl_copy_subarray(#0,#1,#2,#3,#4)"
        :one-liner t :side-effects t))
  #-(or ccl ecl)
  (%portable-copy-array-data src-array src-ofs dest-array dest-ofs count))

(def (function e) copy-array-data (src-array src-ofs dest-array dest-ofs count)
  "Copy data elements between arrays. If count is t, it is deduced."
  (declare (type fixnum src-ofs dest-ofs))
  (assert (equal (array-element-type dest-array)
                 (array-element-type src-array)))
  (let ((dest-size (array-total-size dest-array))
        (src-size (array-total-size src-array)))
    (declare (type fixnum dest-size src-size))
    ;; Verify/deduce the region:
    (assert (and (>= dest-ofs 0) (>= src-ofs 0))
            (src-ofs dest-ofs)
            "Negative offset in copy-array-data: ~A -> ~A"
            src-ofs dest-ofs)
    (if (eql count t)
        (setf count (max 0 (min (- dest-size dest-ofs)
                                (- src-size src-ofs))))
        (assert (and (>= count 0)
                     (<= (+ dest-ofs count) dest-size)
                     (<= (+ src-ofs count) src-size))
                (src-ofs dest-ofs count)
                "Copy region out of bounds: ~A (~A left) -> ~A (~A left): ~A elements."
                src-ofs (- src-size src-ofs)
                dest-ofs (- dest-size dest-ofs) count))
    ;; Copy data
    (when (> count 0)
      (%copy-array-data src-array src-ofs dest-array dest-ofs count))
    ;; Return the count
    count))

