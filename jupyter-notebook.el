;;; jupyter-notebook.el --- Notebook interface -*- lexical-binding: t -*-

;; Copyright (C) 2018 Nathaniel Nicandro

;; Author: Nathaniel Nicandro <nathanielnicandro@gmail.com>
;; Created: 23 Jan 2018
;; Version: 0.7.1

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2, or (at
;; your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;; Currently the conversion to an org-mode file relies on pandoc. There is no
;; conversion from org-mode to a notebook yet. This should probably be done
;; using the export machinery of org-mode.

;;; Code:

(defgroup jupyter-notebook nil
  "Notebook interface"
  :group 'jupyter)

(eval-when-compile (require 'subr-x))
(require 'jupyter-org-client)
(require 'jupyter-messages)

(defvar jupyter-notebook--live-procs nil
  "A list of pandoc processes converting markdown to `org-mode' syntax.")

(defvar jupyter-notebook--max-procs 5
  "The maximum number of live pandoc processes.")

(cl-defstruct jupyter-notebook
  nbformat cells kernel-info language-info)

(defun jupyter-notebook-split-source (source)
  (if (listp source) source
    (split-string source "^" t)))

(defvar org-export-with-toc)

(defun jupyter-notebook-parse-data ()
  (require 'ox-md)
  (let* (org-export-with-toc
         (data
          (org-element-map (org-element-parse-buffer 'greater-element)
              '(headline paragraph src-block)
            (lambda (el)
              (cl-case (org-element-type el)
                (headline
                 (list 'markdown-cell
                       (org-export-string-as
                        (concat (make-string (org-element-property :level el) ?*)
                                " " (org-element-property :title el))
                        'md t)))
                (paragraph
                 (list 'markdown-cell
                       (org-export-string-as
                        (buffer-substring-no-properties
                         (org-element-property :contents-begin el)
                         (org-element-property :contents-end el))
                        'md t)))
                (src-block
                 (let ((code (org-element-property :value el))
                       (metadata nil)
                       (outputs
                        (when-let* ((res (org-babel-where-is-src-block-result)))
                          (org-with-point-at res
                            (jupyter-notebook-parse-outputs)))))
                   (list 'code-cell code outputs metadata))))))))
    (nreverse
     (cl-reduce
      (lambda (a b)
        (if (and (eq (car b) 'markdown-cell)
                 (eq (caar a) 'markdown-cell))
            (setcar a (list 'markdown-cell
                            (concat (nth 1 (car a)) (nth 1 b))))
          (push b a))
        a)
      data
      :initial-value nil))))

(defvar org-html-format-table-no-css)

(defun jupyter-notebook-parse-outputs ()
  (let ((context (org-element-context)))
    (or
     (cl-case (org-element-type context)
       (keyword
        ;; Empty results, only a RESULTS keyword
        nil)
       (drawer
        ;; A results drawer
        (save-restriction
          (narrow-to-region
           (save-excursion
             (goto-char (org-element-property :begin context))
             (line-beginning-position 2))
           (save-excursion
             (goto-char (jupyter-org-element-end-before-blanks context))
             (line-beginning-position 0)))
          (goto-char (point-min))
          (cl-loop
           vconcat (jupyter-notebook-parse-outputs)
           while (/= (org-forward-element) (point-max)))))
       (table
        (save-restriction
          (narrow-to-region (org-element-property :begin context)
                            (org-element-property :end context))
          (let ((org-html-format-table-no-css t))
            (vector
             (jupyter-notebook-execute-result-output
              :execution-count 0
              :data (list :text/html (org-export-as 'html nil nil 'body-only)))))))
       ;; Ambiguity between stream results and final result output
       (fixed-width
        (vector
         (jupyter-notebook-execute-result-output
          ;; TODO: Global execution count for notebook
          :execution-count 0
          :data (list :text/plain (org-element-property :value context)))))
       (_
        ;; A result that passes `jupyter-org-babel-result-p'
        ;; TODO: One issue here is that results that look like tables get
        ;; converted into `org-mode' tables and information is lost there.
        ;; Probably the best option here is to convert into an `html' table.

        ))
     (vector))))

(cl-defun jupyter-notebook-markdown-cell (&key source metadata)
  (list :cell_type "markdown" :metadata (or metadata jupyter--empty-dict)
        :source (jupyter-notebook-split-source source)))

(cl-defun jupyter-notebook-code-cell (&key execution-count
                                           source
                                           collapsed
                                           autoscroll
                                           (outputs []))
  (list :cell_type "code"
        :execution_count execution-count
        :metadata (list :collapsed (if collapsed t jupyter--false)
                        :autoscroll (if (null autoscroll) jupyter--false autoscroll))
        :source (jupyter-notebook-split-source source)
        :outputs outputs))

(cl-defun jupyter-notebook-raw-cell (&key source metadata)
  (list :cell_type "raw"
        :source (jupyter-notebook-split-source source)
        :metadata (or metadata jupyter--empty-dict)))

(cl-defun jupyter-notebook-stream-output (&key name text)
  (list :output_type "stream"
        :name name
        :text (jupyter-notebook-split-source text)))

;; FIXME: Ambiguity with display-data output and execute-result output, when
;; would an image be an execute result and when would it be a display data
;; output? If we have a results drawer then there is possibly stream output or
;; display data output. Without a results drawer then the ambiguity is if there
;; is stream output or an execute result.
;;
;; Maybe I should prepend an Out[N] comment before the execute result to
;; distinguish it from other results, then it would be easier to determine what
;; kind of data is present.
(cl-defun jupyter-notebook-display-data-output (&key data metadata)
  (list :output_type "display_data"
        :data data
        :metadata (or metadata jupyter--empty-dict)))

(cl-defun jupyter-notebook-execute-result-output (&key execution-count data metadata)
  (list :output_type "execute_result"
        :data data
        :metadata (or metadata jupyter--empty-dict)
        :execution_count execution-count))

(cl-defun jupyter-notebook-error-output (&key ename evalue traceback)
  (list :output_type "error"
        :ename ename
        :evalue evalue
        :traceback traceback))

(defun jupyter-notebook-read-file (file)
  "Return the JSON for a notebook FILE."
  (jupyter-read-plist file))

(defun jupyter-notebook--markdown-to-org (element source)
  "Set ELEMENT's contents to the result of calling pandoc on SOURCE.
SOURCE is assumed to be markdown formatted text and will be
converted to `org-mode' syntax and set as the
`org-element-contents' of ELEMENT.

This process is done asynchronously and the process responsible
for setting the contents of ELEMENT is returned."
  (while (> (length jupyter-notebook--live-procs) jupyter-notebook--max-procs)
    (sleep-for 0.1))
  (let* ((process-connection-type nil)
         (proc (start-process "pandoc" nil "pandoc"
                              "-f" "markdown" "-t" "org" "--")))
    (push proc jupyter-notebook--live-procs)
    (prog1 proc
      (set-process-sentinel
       proc (lambda (proc _)
              (when (memq (process-status proc) '(exit signal))
                (cl-callf2 delq proc jupyter-notebook--live-procs)
                (org-element-set-contents
                 element
                 "\n"
                 (org-element-normalize-string
                  (mapconcat #'identity
                             (nreverse (process-get proc :org)) ""))
                 "\n"))))
      (set-process-filter
       proc (lambda (proc output)
              (push output (process-get proc :org))))
      (process-send-string proc (mapconcat #'identity source ""))
      (process-send-eof proc))))

(defun jupyter-notebook--output-to-org (output)
  (let ((head (cdr (plist-get output :data))))
    (while head
      (when (vectorp (car head))
        (setcar head (mapconcat #'identity (car head) "")))
      (setq head (cddr head))))
  (pcase (plist-get output :output_type)
    ("error"
     ;; TODO
     "Error")
    ("stream"
     (jupyter-org-scalar (mapconcat #'identity (plist-get output :text) "")))
    ((or "display_data" "execute_result")
     ;; TODO: Get rid of having to mock a request object
     (jupyter-org-result (jupyter-org-request) output))))

(defun jupyter-notebook--code-to-org (cell source lang)
  (list
   "\n"
   (org-element-put-property
    (jupyter-org-src-block lang ""
      (mapconcat #'identity source ""))
    :post-blank 1)
   (list 'keyword (list :key "RESULTS" :value ""))
   (let ((outputs (mapcar #'jupyter-notebook--output-to-org
                     (plist-get cell :outputs))))
     (unless (zerop (length outputs))
       (if (and (= (length outputs) 1)
                (jupyter-org-babel-result-p (car outputs)))
           (car outputs)
         (apply #'jupyter-org-results-drawer outputs))))))

(defun jupyter-notebook-to-org (file)
  "Construct an Org buffer based on a notebook FILE."
  (interactive (list (read-file-name "File: ")))
  (let* ((nb (jupyter-read-plist file))
         (cells (append (plist-get nb :cells) nil))
         (lang-info (plist-get (plist-get nb :metadata) :language_info))
         (jupyter-lang (concat "jupyter-" (plist-get lang-info :name)))
         (buf (find-file-noselect (concat (file-name-base file) ".org")))
         (tree nil))
    (dolist (cell cells)
      (cl-destructuring-bind (&key cell_type _metadata source &allow-other-keys)
          cell
        (push
         (pcase cell_type
           ("markdown"
            (let ((paragraph (list 'paragraph nil)))
              (prog1 paragraph
                (jupyter-notebook--markdown-to-org paragraph source))))
           ("code"
            (when source
              (jupyter-notebook--code-to-org cell source jupyter-lang))))
         tree)))
    (while jupyter-notebook--live-procs
      (accept-process-output nil 1))
    (with-current-buffer buf
      (erase-buffer)
      (insert (org-element-interpret-data (nreverse tree)))
      (pop-to-buffer buf))))

(provide 'jupyter-notebook)

;;; jupyter-notebook.el ends here
