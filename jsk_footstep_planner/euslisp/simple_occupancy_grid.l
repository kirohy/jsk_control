;; Utility to deal with jsk_recognition_msgs::SimpleOccupancyGrid(Array)
(load "package://jsk_footstep_planner/euslisp/footstep_planner_util.l")
(ros::roseus-add-msgs "jsk_recognition_msgs")

(defun quaternion-from-two-vectors (a b)
  (let* ((v0 (normalize-vector a))
         (v1 (normalize-vector b))
         (c (v. v1 v0)))
    (if (eps= c -1.0)
        (float-vector -1 0 0 0)
      (let* ((axis (v* v0 v1))
             (s (sqrt (* 2 (+ 1 c))))
             (invs (/ 1.0 s)))
        (let ((vec (scale invs axis))
              (w (* 0.5 s)))
          (normalize-vector (float-vector w (elt vec 0) (elt vec 1) (elt vec 2))))))))

(defun coefficients->plane-coords (coefficients)
  (let ((z-axis (normalize-vector (float-vector (elt coefficients 0)
                                                (elt coefficients 1)
                                                (elt coefficients 2))))
        (unitz (float-vector 0 0 1)))
    (let ((c (make-coords :rot (quaternion2matrix (quaternion-from-two-vectors unitz z-axis)))))
      (send c :translate (float-vector 0 0 (- (* 1000.0 (elt coefficients 3))))))))

(defclass occupancy-grid
  :super propertied-object
  :slots (resolution
          coefficients plane-coords frame-id cell-hash plane-obj
          cell-num
          local-point-cache point-tmp point-tmp2 rot-tmp
          occupiedp-timer on-plane-p-timer index-pair-timer
          placablep-timer inverse-transform-vector-timer
          ))

(defmethod occupancy-grid
  (:init (msg global-trans)
    "Instantiating from ros message"
    (send self :init-common)
    (setq frame-id (send msg :header :frame_id))
    (setq resolution (* 1000 (send msg :resolution)))
    (setq coefficients (send msg :coefficients))
    (setq plane-coords
          (send (send global-trans :copy-worldcoords)
                :transform (coefficients->plane-coords coefficients)))
    (setq plane-obj (instance plane :init
                              (send plane-coords :rotate-vector (float-vector 0 0 1))
                              (send plane-coords :worldpos)))
    ;; hash table
    (setq cell-num (length (send msg :cells)))
    (setq cell-hash (make-hash-table :test #'equal
                                     :size cell-num
                                     :rehash-size 1.1))
    (dolist (cell-point (send msg :cells))
      ;; cell-point is geometry_msgs::Point
      (let ((cell-x (* 1000 (send cell-point :x)))
            (cell-y (* 1000 (send cell-point :y))))
        (let ((index-key (send self :index-pair (float-vector cell-x cell-y 0) :local t)))
          (setf (gethash index-key cell-hash) t))))
    self)
  (:init-common ()
    (setq local-point-cache (float-vector 0 0 0))
    (setq point-tmp (float-vector 0 0 0))
    (setq point-tmp2 (float-vector 0 0 0))
    (setq rot-tmp (make-matrix 3 3))
    (setq occupiedp-timer (instance counter-timer :init ":occupiedp"))
    (setq on-plane-p-timer (instance counter-timer :init ":on-plane-p"))
    (setq index-pair-timer (instance counter-timer :init ":index-pair"))
    (setq placablep-timer (instance counter-timer :init ":placablep"))
    (setq inverse-transform-vector-timer
          (instance counter-timer :init ":inverse-transform-vector"))
    )
  (:init-from-face (f &optional (aresolution 5))
    (send self :init-common)
    (setq resolution aresolution)
    (let ((normal (send f :normal))
          (c (cadr (send f :centroid))))
      (let ((d (- (v. normal c))))
        (setq coefficients (float-vector (elt normal 0)
                                         (elt normal 1)
                                         (elt normal 2)
                                         (* 0.001 d)))))
    (setq plane-coords (coefficients->plane-coords coefficients))
    (setq plane-obj (instance plane :init
                              (send plane-coords :rotate-vector (float-vector 0 0 1))
                              (send plane-coords :worldpos)))
    ;; fill cells
    (setq cell-num 0)
    (setq cell-hash (make-hash-table :test #'equal))
    (let ((local-vertices
           (mapcar #'(lambda (v)
                       (send plane-coords :inverse-transform-vector v))
                   (cdr (send f :vertices)))))
      (let* ((bbox (make-bounding-box local-vertices))
             (min-point (send bbox :minpoint))
             (max-point (send bbox :maxpoint)))
        (let ((cell-x (elt min-point 0)))
          (while (<= cell-x (elt max-point 0))
            (let ((cell-y (elt min-point 1)))
              (while (<= cell-y (elt max-point 1))
                (let ((p (send plane-coords :transform-vector
                               (float-vector cell-x cell-y 0))))
                  (when (not (eq (send f :insidep p) :outside))
                    (setf (gethash (send self :index-pair (float-vector cell-x cell-y 0)
                                         :local t)
                                   cell-hash)
                          t)
                    (incf cell-num))
                (setq cell-y (+ cell-y resolution))))
              (setq cell-x (+ cell-x resolution))
              ))))))
  (:local-point (index-pair)
    (float-vector (* resolution (car index-pair))
                  (* resolution (cdr index-pair))
                  0))
  (:global-point (index-pair)
    (send plane-coords :transform-vector (send self :local-point index-pair)))
  (:prepare-for-planning ()
    "This method is called bedfore each planning"
    (send occupiedp-timer :reset-timer)
    (send on-plane-p-timer :reset-timer)
    (send index-pair-timer :reset-timer)
    (send placablep-timer :reset-timer)
    (send inverse-transform-vector-timer :reset-timer))
  (:report ()
    (send occupiedp-timer :report)
    (send on-plane-p-timer :report)
    (send index-pair-timer :report)
    (send placablep-timer :report)
    (send inverse-transform-vector-timer :report)
    )
  (:plane () plane-obj)
  (:on-plane-p (p n)
    "Check whether p (in global coordinates) is on the plane or not"
    (bench-timer
     on-plane-p-timer
     (and
      (> (v. (send plane-obj :normal) n) 0.95)
      (send plane-obj :on-plane-p p 10.0))))  ;1cm error is allowed
  (:cell-num () cell-num)
  (:worldcoords ()
    plane-coords)
  (:vertices ()
    (let ((ret nil))
      (maphash #'(lambda (key val)
                   (setf ret (cons (send self :global-point key) ret)))
               cell-hash)
      ret))
  (:collision-check-objects ()
    nil)
  (:draw (vwer)
    (gl::glPushAttrib gl::GL_ALL_ATTRIB_BITS)
    (gl::glDisable gl::GL_LIGHTING)
    (let ((col (gl::find-color (get self :face-color)))
          (w (/ resolution 2.0)))
      (maphash #'(lambda (key val)
                   (let* ((center (send self :local-point key))
                          (v1 (v+ center
                                  (float-vector w w 0)))
                          (v2 (v+ center
                                  (float-vector (- w) w 0)))
                          (v3 (v+ center
                                  (float-vector (- w) (- w) 0)))
                          (v4 (v+ center
                                  (float-vector w (- w) 0))))
                     (let ((gv1 (send plane-coords :transform-vector v1))
                           (gv2 (send plane-coords :transform-vector v2))
                           (gv3 (send plane-coords :transform-vector v3))
                           (gv4 (send plane-coords :transform-vector v4)))
                       (gl::glBegin gl::GL_LINE_STRIP)
                       (gl::glColor3fv col)
                       (gl::glVertex3fv gv1)
                       (gl::glColor3fv col)
                       (gl::glVertex3fv gv2)
                       (gl::glColor3fv col)
                       (gl::glVertex3fv gv3)
                       (gl::glColor3fv col)
                       (gl::glVertex3fv gv4)
                       (gl::glColor3fv col)
                       (gl::glVertex3fv gv1)
                       (gl::glEnd)
                       )))
               cell-hash))
    (gl::glEnable gl::GL_LIGHTING)
    (gl::glPopAttrib)
    )
  (:project-coords (coords)
    "Project coordinates on to the plane and it does not take into account
which is inside of occupied cell"
    (let ((point (send plane-obj :project (send coords :worldpos))))
      ;; rotation
      (let ((rot (quaternion2matrix
                  (quaternion-from-two-vectors
                   (send coords :rotate-vector (float-vector 0 0 1))
                   (send plane-coords :rotate-vector (float-vector 0 0 1))))))
        (let ((ret (make-coords :pos point :rot (m* (send coords :rot) rot))))
          (setf (get ret :projected-grid) self)
          ret))))
  (:placablep (point n)
    (bench-timer2
     placablep-timer
     (let ((dot (abs (v. (send plane-obj :normal) n))))
       (if (or (> dot 1.0) (< (rad2deg (acos dot)) 5))
           (progn
             ;; (transpose (send plane-coords :rot) rot-tmp)
             ;; (transform rot-tmp point point-tmp)
             ;; (transform rot-tmp (send plane-coords :worldpos) point-tmp2)
             ;; (v- point-tmp point-tmp2 local-point-cache)
             (setq local-point-cache (bench-timer2
                                      inverse-transform-vector-timer
                                      (send plane-coords :inverse-transform-vector point)))
             (if (< (abs (elt local-point-cache 2)) 10.0)
                 (send self :occupiedp
                       (send self :index-pair local-point-cache :local t))))
         (progn
           ;;(ros::ros-info "theta is ~A" (rad2deg (acos dot)))
           nil)
         ))))
  (:index-pair (pos &key (local t))
    (bench-timer2
     index-pair-timer
     (unless local
       ;; convert to local coordinates
       (setq pos (send plane-coords :inverse-transform-vector pos)))
     (cons (round (/ (elt pos 0) resolution))
           (round (/ (elt pos 1) resolution)))
     ))
  (:occupiedp (index-pair)
    (bench-timer2
     occupiedp-timer
     (gethash index-pair cell-hash)))
  )

;; Utilify functions for grid-maps (array of occupancy-grid)

(defun lookup-highest-corresponding-grid-map (coords grid-maps)
  (let ((max-height -10000)
        (max-grid nil))
    (dolist (grid grid-maps)
      (let ((projected-coords (send grid :project-coords coords)))
        (if (send grid :occupiedp
                  (send grid :index-pair (send projected-coords :worldpos)
                        :local nil))
          (let ((height (elt (send projected-coords :worldpos) 2)))
            (when (> height max-height)
              (setq max-height height)
              (setq max-grid grid))))))
    max-grid))


(defun range (num)
  (let ((ret nil))
    (dotimes (i num)
      (push i ret))
    (nreverse ret)))

(setq *face-sampling-num* 2)
(setq *sampling-points-cache* (mapcar #'(lambda (i)
                                          (float-vector 0 0 0))
                                      (range (* (1+ *face-sampling-num*)
                                                (1+ *face-sampling-num*)))))

(defun sampling-foot-points (leg-cube &optional (num *face-sampling-num*))
  (send leg-cube :worldpos)             ;need?
  (let ((bottom-face (find-if #'(lambda (f)
                                  (eq (cadr (send f :face-id)) :bottom))
                              (send leg-cube :faces))))
    (sampling-face-points bottom-face num)))


(defun sampling-face-points (bottom-face
                             &optional
                             (num *face-sampling-num*)
                             (ret (mapcar #'(lambda (i)
                                              (float-vector 0 0 0))
                                          (range (* (1+ num) (1+ num))))))
  (let ((vertices (cdr (send bottom-face :vertices))))
    (let* ((ex (v- (elt vertices 1) (elt vertices 0)))
           (ey (v- (elt vertices 3) (elt vertices 0)))
           (x-length (norm ex))
           (y-length (norm ey)))
      (let ((ux (normalize-vector ex))
            (uy (normalize-vector ey)))
        (dotimes (ix (1+ num))
          (dotimes (iy (1+ num))
            (let ((c (v+ (scale (* (/ x-length num) ix) ux)
                         (v+ (scale (* (/ y-length num) iy) uy)
                             (elt vertices 0)))))
              (setf (elt ret (+ iy (* ix (1+ num)))) c))))
        ret))))

(defun cube-placable-p (leg-cube grids)
  (let ((bottom-face (find-if #'(lambda (f)
                                  (eq (cadr (send f :face-id)) :bottom))
                              (send leg-cube :faces))))
    (face-placable-p bottom-face grids)))

(defun face-placable-p (leg-face grids-or-grid)
  (if (atom grids-or-grid)
      (_face-placable-p leg-face grids-or-grid)
    (_face-placable-p/list leg-face grids-or-grid)))

(defun _face-placable-p/list (leg-face grids)
  (if (null grids)
      t
    (dolist (g grids)                 ;Should cache previous result
      (if (_face-placable-p leg-face g)
          (return-from _face-placable-p/list t)))))

(defun _face-placable-p (leg-face grid)
  (if (null grid)
      t
    (let ((points (sampling-face-points
                   leg-face
                   *face-sampling-num* *sampling-points-cache*))
          (all-foundp t))
      ;;(send-all points :draw-on :flush t)
      (dotimes (i (length points))
        (unless (send grid :placablep (elt points i) (send leg-face :normal))
          ;;(ros::ros-info "~A is not placable" (elt points i))
          (return-from _face-placable-p nil)))
      t)))

(defun append-footstep-candidates-by-grids (next-coords-candidate grids)
  ;; next-coords-candidate =  ((transformation . next-leg-pose) ...)
  (if (null grids)
      next-coords-candidate
  (let ((new-candidates nil))
    (dolist (grid grids)
      (dolist (candidate next-coords-candidate)
        (let ((projected-coords (send grid :project-coords (cdr candidate))))
          ;; Check center only first
          (if (send grid :occupiedp
                    (send grid
                          :index-pair (send projected-coords :worldpos)
                          :local nil))
              (progn
                ;; memoize projecting grid
                (setf (get projected-coords :projecting-grid) grid)
                (setq new-candidates (cons
                                      (cons (car candidate)
                                            projected-coords)
                                      new-candidates)))))))
    new-candidates)))

#|
(load "package://jsk_footstep_planner/euslisp/simple_occupancy_grid.l")
(ros::roseus "hoge")
(setq *tf* (instance ros::transform-listener :init))
(defun callback (msg)
  (setq *grids* (remove-if #'null (mapcar #'(lambda (g)
                            (let ((trans (lookup-transform-with-duration
                                          *tf*
                                          "map"
                                          (send g :header :frame_id)
                                          (send g :header :stamp)
                                          1.0)))
                              (if trans
                                  (instance occupancy-grid :init g trans))))
                        (send msg :grids))))
  (dotimes (i (length *grids*))
    (setf (get (elt *grids* i) :face-color) (gl::color-category20 i)))
  (objects *grids*))
(ros::subscribe "/locomotion/env_server/output" jsk_recognition_msgs::SimpleOccupancyGridArray #'callback)
(ros::spin-once)
|#