;;; skeletor.el --- Provides project skeletons for Emacs

;; Copyright (C) 2013 Chris Barrett

;; Author: Chris Barrett <chris.d.barrett@me.com>
;; Package-Requires: ((s "1.7.0") (f "0.14.0") (dash "2.2.0") (cl-lib "0.3") (emacs "24.1"))
;; Version: 0.1

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Provides project skeletons for Emacs.
;;
;; To create a new project interactively, run 'M-x create-project'.
;;
;; To define a new project, create a project template inside
;; `skel-user-directory', then configure the template with the
;; `define-project-skeleton' macro.
;;
;; See the info manual for all the details.

;;; Code:

(eval-when-compile
  ;; Add cask packages to load path so flycheck checkers work.
  (when (boundp' flycheck-emacs-lisp-load-path)
    (dolist (it (file-expand-wildcards "./.cask/*/elpa/*"))
      (add-to-list 'flycheck-emacs-lisp-load-path it))))

(require 'dash)
(require 's)
(require 'f)
(require 'cl-lib)

(defvar skel-project-skeletons nil
  "The list of available project skeletons.")

(defgroup skeletor nil
  "Provides customisable project skeletons for Emacs."
  :group 'tools
  :prefix "skel-"
  :link '(custom-manual "(skeletor)Top")
  :link '(info-link "(skeletor)Usage"))

(defcustom skel-user-directory (f-join user-emacs-directory "project-skeletons")
  "The directory containing project skeletons.
Each directory inside is available for instantiation as a project
skeleton."
  :group 'skeletor
  :type 'directory)

(defcustom skel-project-directory (f-join (getenv "HOME") "Projects")
  "The directory where new projects will be created."
  :group 'skeletor
  :type 'directory)

(defcustom skel-default-replacements
  (list (cons "__YEAR__" (format-time-string "%Y"))
        (cons "__USER-NAME__" user-full-name)
        (cons "__USER-MAIL-ADDRESS__" user-mail-address)
        (cons "__ORGANISATION__" (if (boundp 'user-organisation)
                                     user-organisation
                                   user-full-name)))
  "A list of replacements available for expansion in project skeletons.

Each alist element is comprised of (candidate . replacement),
where 'candidate' will be substituted for 'replacement'.
'replacement' may be a simple string, a variable that will be
evaluated or a function that will be called."
  :group 'skeletor
  :type '(alist :key-type 'string
                :value-type (choice string variable function)))

(defcustom skel-init-with-git t
  "When non-nil, initialise newly created projects with a git repository."
  :group 'skeletor
  :type 'boolean)

(defcustom skel-after-project-instantiated-hook nil
  "Hook run after a project is successfully instantiated.
Each function will be passed the path of the newly instantiated
project."
  :group 'skeletor
  :type 'hook)

(defgroup skeletor-python nil
  "Configuration for python projects in skeletor."
  :group 'tools
  :prefix "skel-python-")

(defcustom skel-python-bin-search-path '("/usr/bin" "/usr/local/bin")
  "A list of paths to search for python binaries.

Python binaries found in these paths will be shown as canditates
when initialising virtualenv."
  :group 'skeletor-python
  :type '(repeat directory))

;;;;;;;;;;;;;;;;;;;;;;;; Internal ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar skel--pkg-root (f-dirname (or load-file-name (buffer-file-name)))
  "The base directory of the skeletor package.")

(defvar skel--directory
  (f-join skel--pkg-root "project-skeletons")
  "The directory containing built-in project skeletons.
Each directory inside is available for instantiation as a project
skeleton.")

(defvar skel--licenses-directory (f-join skel--pkg-root "licenses")
  "The directory containing license files for projects.")

(defvar skel--shell-buffer-name "*Skeleton Shell Output*"
  "The name of the buffer for displaying shell command output.")

(defun skel--replace-all (replacements s)
  "Like s-replace-all, but perform fixcase replacements.
REPLACEMENTS is an alist of (str . replacement), and S is the
string to process."
  (replace-regexp-in-string (regexp-opt (mapcar 'car replacements))
                            (lambda (it) (s--aget replacements it))
                            s 'fixcase))

(defun skel--instantiate-template-file (file replacements)
  "Initialise an individual file.

* FILE is the path to the file.

* REPLACEMENTS is an alist of substitutions to perform in the file."
  (with-temp-file file
    (insert-file-contents-literally file)
    (--each replacements
      (goto-char 0)
      (while (search-forward (car it) nil t)
        (replace-match (cdr it) 'fixcase 'literal)))))

(defun skel--instantiate-template-directory (template dest replacements)
  "Create the directory for TEMPLATE at destination DEST.
Performs the substitutions specified by REPLACEMENTS."
  (let ((tmpd (make-temp-file "project-skeleton__" t)))
    (unwind-protect

        (progn
          (--each (f-entries (or (f-expand template skel--directory)
                                 (f-expand template skel-user-directory)))
            (f-copy it tmpd))

          ;; Process file name and contents according to replacement rules.
          (--each (f-entries tmpd nil t)
            (let ((updated (skel--replace-all replacements it)))
              (unless (equal updated it)
                (rename-file it updated))))

          (--each (f-files tmpd nil t)
            (skel--instantiate-template-file it replacements))

          (copy-directory tmpd dest)))

    (delete-directory tmpd t)))

(defun skel--instantiate-license-file (license-file dest replacements)
  "Populate the given license file template.
* LICENSE-FILE is the path to the template license file.

* DEST is the path it will be copied to.

* REPLACEMENTS is an alist passed to `skel--replace-all'."
  (f-write (skel--replace-all replacements (f-read license-file)) 'utf-8 dest))

(defun skel-read-license (prompt default)
  "Prompt the user to select a license.

* PROMPT is the prompt shown to the user.

* DEFAULT a regular expression used to find the default."
  (let* ((xs (--map (cons (s-upcase (f-filename it)) it)
                    (f-files skel--licenses-directory)))
         (d (car (--first (s-matches? default (car it)) xs)))
         (choice (ido-completing-read prompt (-map 'car xs) nil t d)))
    (cdr (assoc choice xs))))

(defun skel--eval-replacements (replacement-alist)
  "Evaluate REPLACEMENT-ALIST.
Evaluates the cdr of each item in the alist according to the following rules:
* If the item is a lambda-function or function-name it will be called
* If it is a symbol will be eval'ed
* Otherwise the item will be used unchanged."
  (--map (cl-destructuring-bind (fst . snd) it
           (cons fst
                 (cond ((functionp snd)
                        (if (commandp snd)
                            (call-interactively snd)
                          (funcall snd)))
                       ((symbolp snd)
                        (eval snd))
                       (t
                        snd))))
         replacement-alist))

(defun skel--initialize-git-repo  (dir)
  "Initialise a new git repository at DIR."
  (when skel-init-with-git
    (message "Initialising git...")
    (shell-command
     (format "cd %s && git init && git add -A && git commit -m 'Initial commit'"
             (shell-quote-argument dir)))
    (message "Initialising git...done")))

;;;;;;;;;;;;;;;;;;;;;;;; User commands ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(cl-defmacro define-project-skeleton
    (name &key replacements after-creation default-license)
  "Declare a new project type

* NAME is a string naming the project type. A corresponding
  skeleton should exist in `skel--directory' or
  `skel-user-directory'.

* REPLACEMENTS is an alist of (string . replacement) used specify
  substitutions when initialising the project from its skeleton.

* DEFAULT-LICENSE is a regexp matching the name of a license to
  be used as the default when reading from the user.

* AFTER-CREATION is a unary function to be run once the project
  is created. It should take a single argument--the path to the
  newly-created project."
  (declare (indent 1))
  (cl-assert (or (symbolp name) (stringp name)) t)
  (let ((constructor (intern (format "create-%s" name)))
        (default-license-var (intern (format "%s-default-license" name)))
        (rs (eval replacements)))
    (cl-assert (listp rs) t)
    (cl-assert (-all? 'stringp (-map 'car rs)) t)

    `(progn
       (defvar ,default-license-var ,default-license
         ,(concat "Auto-generated variable.\n\n"
                  "The default license type for " name " skeletons.") )

       (defun ,constructor (project-name license-file)

         ,(concat
           "Auto-generated function.\n\n"
           "Interactively creates a new " name " skeleton.\n"
           "
* PROJECT-NAME is the name of this project instance.

* LICENSE-FILE is the path to a license file to be added to the project.")

         (interactive (list (read-string "Project name: ")
                            (skel-read-license "License: " (eval ,default-license-var))))

         (let* ((dest (f-join skel-project-directory project-name))
                (default-directory dest)
                (repls (-map 'skel--eval-replacements
                             (-concat (eval ',rs)
                                      (list (cons "__PROJECT-NAME__" project-name))
                                      skel-default-replacements))))

           (skel--instantiate-template-directory ,name dest repls)
           (skel--instantiate-license-file license-file (f-join dest "COPYING") repls)
           (funcall ,after-creation dest)
           (skel--initialize-git-repo dest)
           (run-hook-with-args 'skel-after-project-instantiated-hook default-directory)
           (message "Project created at %s" dest)))

       (add-to-list 'skel-project-skeletons (cons ,name ',constructor)))))

;;;###autoload
(defun create-project (type)
  "Create a project of the given TYPE."
  (interactive (list (completing-read "Skeleton: "
                                      (-sort 'string< (-map 'car skel-project-skeletons))
                                      nil t)))
  (let ((constructor (cdr (assoc type skel-project-skeletons))))
    (call-interactively constructor)))

;;;;;;;;;;;;;;;;;;;;;;;; Define skeletons ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-project-skeleton "elisp-package"
  :default-license (rx bol "gpl")
  :after-creation
  (lambda (dir)
    (async-shell-command
     (concat "cd" (shell-quote-argument dir) "&& make env"))))

(defun skel-py--read-python-bin (dir)
  "Initialise a virtualenv environment at DIR."
  (message "Finding python binaries...")
  (->> skel-python-bin-search-path
    (--mapcat
     (f-files it (lambda (f)
                   (s-matches? (rx "python" (* (any digit "." "-")) eol)
                               f))))
    (ido-completing-read "Python binary: ")))

(defun skel-py--create-virtualenv-dirlocals (dir)
  "Create a .dir-locals file in DIR for virtualenv variables."
  (save-excursion
    (add-dir-local-variable nil 'virtualenv-default-directory dir)
    (add-dir-local-variable nil 'virtualenv-workon (f-filename dir))
    (save-buffer)
    (kill-buffer)))

(define-project-skeleton "python-project"
  :default-license (rx bol "bsd")
  :replacements '(("__PYTHON-BIN__" . skel-py--read-python-bin))
  :after-creation
  (lambda (dir)
    (let ((inhibit-redisplay t))
      (skel-py--create-virtualenv-dirlocals dir))

    (async-shell-command
     (format "cd %s && make tooling" (shell-quote-argument dir))
     skel--shell-buffer-name)))

(provide 'skeletor)

;;; skeletor.el ends here