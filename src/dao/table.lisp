(in-package :cl-user)
(defpackage mito.dao.table
  (:use #:cl
        #:mito.util)
  (:import-from #:mito.connection
                #:driver-type)
  (:import-from #:mito.class
                #:table-class
                #:table-primary-key
                #:create-table-sxql)
  (:import-from #:mito.dao.column
                #:dao-table-column-class
                #:dao-table-column-inflate
                #:dao-table-column-deflate)
  (:export #:dao-class
           #:dao-table-class

           #:getoid
           #:dao-synced

           #:inflate
           #:deflate

           #:table-definition))
(in-package :mito.dao.table)

(defclass dao-class () ())

(defclass dao-table-class (table-class)
  ((auto-pk :initarg :auto-pk
            :initform '(t))))

(defmethod c2mop:direct-slot-definition-class ((class table-class) &key)
  'dao-table-column-class)

(defparameter *oid-slot-definition*
  '(:name %oid :col-type :bigserial :primary-key t :readers (getoid)))

(declaim (ftype (function (t) *) dao-synced))
(declaim (ftype (function (t t) *) (setf dao-synced)))
(defparameter *synced-slot-definition*
  `(:name %synced :type boolean :initform nil :initfunction ,(lambda () nil) :readers (dao-synced) :writers ((setf dao-synced)) :ghost t))

(defun initargs-enables-auto-pk (initargs)
  (first (or (getf initargs :auto-pk) '(t))))

(defun initargs-contains-primary-key (initargs)
  (or (getf initargs :primary-key)
      (find-if (lambda (slot)
                 (getf slot :primary-key))
               (getf initargs :direct-slots))))

(defmethod initialize-instance :around ((class dao-table-class) &rest initargs
                                        &key direct-superclasses &allow-other-keys)
  (unless (or (not (initargs-enables-auto-pk initargs))
              (initargs-contains-primary-key initargs))
    (push *oid-slot-definition* (getf initargs :direct-slots)))

  (push *synced-slot-definition* (getf initargs :direct-slots))

  ;; Add relational column slots (ex. user-id)
  (loop for column in (getf initargs :direct-slots)
        for col-type = (getf column :col-type)
        when (and (symbolp col-type)
                  (not (null col-type))
                  (not (keywordp col-type)))
          do (rplacd (cdr column)
                     `(:ghost t ,@(cddr column)))
             (let* ((name (getf column :name))
                    (rel-class (find-class (getf column :col-type)))
                    (pk (first (table-primary-key rel-class))))
               (rplacd (last (getf initargs :direct-slots))
                       `((:name ,(intern
                                  (format nil "~A-~A" (getf column :col-type) pk)
                                  (symbol-package name))
                          ;; Defer retrieving the relational column type until table-column-info
                          :col-type nil
                          :rel-key ,(get-slot-by-slot-name rel-class pk)
                          :rel-key-fn
                          ,(lambda (obj)
                             (and (slot-boundp obj name)
                                  (slot-value (slot-value obj name) pk))))))))

  (unless (contains-class-or-subclasses 'dao-class direct-superclasses)
    (setf (getf initargs :direct-superclasses)
          (cons (find-class 'dao-class) direct-superclasses)))
  (apply #'call-next-method class initargs))

(defmethod reinitialize-instance :around ((class dao-table-class) &rest initargs)
  (if (or (not (initargs-enables-auto-pk initargs))
          (initargs-contains-primary-key initargs))
      (setf (getf initargs :direct-slots)
            (remove '%oid (getf initargs :direct-slots)
                    :key #'car
                    :test #'eq))
      (push *oid-slot-definition* (getf initargs :direct-slots)))

  (push *synced-slot-definition* (getf initargs :direct-slots))

  (apply #'call-next-method class initargs))

(defmethod c2mop:ensure-class-using-class :around ((class dao-table-class) name &rest keys
                                                   &key direct-superclasses &allow-other-keys)
  (unless (contains-class-or-subclasses 'dao-class direct-superclasses)
    (setf (getf keys :direct-superclasses)
          (cons (find-class 'dao-class) direct-superclasses)))
  (apply #'call-next-method class name keys))

(defgeneric inflate (object slot-name value)
  (:method ((object dao-class) slot-name value)
    (let* ((slot (get-slot-by-slot-name (class-of object) slot-name))
           (inflate (dao-table-column-inflate slot)))
      (if inflate
          (funcall inflate value)
          value))))

(defgeneric deflate (object slot-name value)
  (:method ((object dao-class) slot-name value)
    (let* ((slot (get-slot-by-slot-name (class-of object) slot-name))
           (deflate (dao-table-column-deflate slot)))
      (if deflate
          (funcall deflate value)
          value))))

(defun table-definition (class &key if-not-exists)
  (when (symbolp class)
    (setf class (find-class class)))
  (check-type class table-class)
  (create-table-sxql class (driver-type)
                     :if-not-exists if-not-exists))