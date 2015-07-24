// -*- mode: c++ -*-
/*********************************************************************
 * Software License Agreement (BSD License)
 *
 *  Copyright (c) 2015, JSK Lab
 *  All rights reserved.
 *
 *  Redistribution and use in source and binary forms, with or without
 *  modification, are permitted provided that the following conditions
 *  are met:
 *
 *   * Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 *   * Redistributions in binary form must reproduce the above
 *     copyright notice, this list of conditions and the following
 *     disclaimer in the documentation and/o2r other materials provided
 *     with the distribution.
 *   * Neither the name of the JSK Lab nor the names of its
 *     contributors may be used to endorse or promote products derived
 *     from this software without specific prior written permission.
 *
 *  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 *  "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 *  LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 *  FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
 *  COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
 *  INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
 *  BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 *  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 *  CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 *  LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
 *  ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 *  POSSIBILITY OF SUCH DAMAGE.
 *********************************************************************/

#include "jsk_footstep_planner/footstep_graph.h"

namespace jsk_footstep_planner
{
  void FootstepGraph::setBasicSuccessors(
    std::vector<Eigen::Affine3f> left_to_right_successors)
  {
    successors_from_left_to_right_ = left_to_right_successors;
    for (size_t i = 0; i < successors_from_left_to_right_.size(); i++) {
      Eigen::Affine3f transform = successors_from_left_to_right_[i];
      float roll, pitch, yaw;
      pcl::getEulerAngles(transform, roll, pitch, yaw);
      Eigen::Vector3f translation = transform.translation();
      Eigen::Affine3f flipped_transform
        = Eigen::Translation3f(translation[0], -translation[1], translation[2])
        * Eigen::Quaternionf(Eigen::AngleAxisf(-yaw, Eigen::Vector3f::UnitZ()));
      successors_from_right_to_left_.push_back(flipped_transform);
    }

    // max_successor_distance_
    for (size_t i = 0; i < successors_from_left_to_right_.size(); i++) {
      Eigen::Affine3f transform = successors_from_left_to_right_[i];
      double dist = transform.translation().norm();
      if (dist > max_successor_distance_) {
        max_successor_distance_ = dist;
      }
      double rot = Eigen::AngleAxisf(transform.rotation()).angle();
      if (rot > max_successor_rotation_) {
        max_successor_rotation_ = rot;
      }
    }
  }

  bool FootstepGraph::isGoal(StatePtr state)
  {
    FootstepState::Ptr goal = getGoal(state->getLeg());
    if (publish_progress_) {
      jsk_footstep_msgs::FootstepArray msg;
      msg.header.frame_id = "odom";
      msg.header.stamp = ros::Time::now();
      msg.footsteps.push_back(*state->toROSMsg());
      pub_progress_.publish(msg);
    }
    Eigen::Affine3f pose = state->getPose();
    Eigen::Affine3f goal_pose = goal->getPose();
    Eigen::Affine3f transformation = pose.inverse() * goal_pose;
    return (pos_goal_thr_ > transformation.translation().norm()) &&
      (rot_goal_thr_ > std::abs(Eigen::AngleAxisf(transformation.rotation()).angle()));
  }

  std::vector<FootstepState::Ptr>
  FootstepGraph::localMoveFootstepState(FootstepState::Ptr in)
  {
    std::vector<FootstepState::Ptr> moved_states;
    moved_states.reserve(local_move_x_num_ * local_move_y_num_ * local_move_theta_num_ * 8);
    for (size_t xi = - local_move_x_num_; xi <= local_move_x_num_; xi++) {
      for (size_t yi = - local_move_y_num_; yi <= local_move_y_num_; yi++) {
        for (size_t thetai = - local_move_theta_num_; thetai <= local_move_theta_num_; thetai++) {
          Eigen::Affine3f trans(Eigen::Translation3f(local_move_x_ / local_move_x_num_ * xi,
                                                     local_move_y_ / local_move_y_num_ * yi,
                                                     0)
                                * Eigen::AngleAxisf(local_move_theta_ / local_move_theta_num_ * thetai,
                                                    Eigen::Vector3f::UnitZ()));
          moved_states.push_back(
            FootstepState::Ptr(new FootstepState(in->getLeg(),
                                                 in->getPose() * trans,
                                                 in->getDimensions(),
                                                 in->getResolution())));
        }
      }
    }
    return moved_states;
  }
  
  std::vector<FootstepGraph::StatePtr>
  FootstepGraph::successors(StatePtr target_state)
  {
    std::vector<Eigen::Affine3f> transformations;
    int next_leg;
    if (target_state->getLeg() == jsk_footstep_msgs::Footstep::LEFT) {
      transformations = successors_from_left_to_right_;
      next_leg = jsk_footstep_msgs::Footstep::RIGHT;
    }
    else if (target_state->getLeg() == jsk_footstep_msgs::Footstep::RIGHT) {
      transformations = successors_from_right_to_left_;
      next_leg = jsk_footstep_msgs::Footstep::LEFT;
    }
    else {
      // TODO: error
    }

    std::vector<FootstepGraph::StatePtr> ret;
    Eigen::Affine3f base_pose = target_state->getPose();
    for (size_t i = 0; i < transformations.size(); i++) {
      Eigen::Affine3f transform = transformations[i];
      FootstepGraph::StatePtr next(new FootstepState(next_leg,
                                                     base_pose * transform,
                                                     target_state->getDimensions(),
                                                     resolution_));
      if (use_pointcloud_model_ && !lazy_projection_) {
        // Update footstep position by projection
        unsigned int error_state;
        next = projectFootstep(next, error_state);
        if (!next && localMovement() && error_state == projection_state::close_to_success) {
          std::vector<StatePtr> locally_moved_nodes
            = localMoveFootstepState(next);
          for (size_t j = 0; j < locally_moved_nodes.size(); j++) {
            ret.push_back(locally_moved_nodes[j]);
          }
        }
      }
      if (next) {
        ret.push_back(next);
      }
    }
    return ret;
  }


  FootstepState::Ptr FootstepGraph::projectFootstep(FootstepState::Ptr in)
  {
    unsigned int error_state;
    return projectFootstep(in, error_state);
  }
  
  FootstepState::Ptr FootstepGraph::projectFootstep(FootstepState::Ptr in,
                                                    unsigned int& error_state)
  {
    return in->projectToCloud(*tree_model_,
                              pointcloud_model_,
                              grid_search_,
                              *tree_model_2d_,
                              pointcloud_model_2d_,
                              Eigen::Vector3f(0, 0, 1),
                              error_state,
                              0.02,
                              100,
                              100);
  }
  
  bool FootstepGraph::projectGoal()
  {
    unsigned int error_state;
    FootstepState::Ptr left_projected = projectFootstep(left_goal_state_);
    FootstepState::Ptr right_projected = projectFootstep(right_goal_state_);
    if (left_projected && right_projected) {
      left_goal_state_ = left_projected;
      right_goal_state_ = right_projected;
      return true;
    }
    else {
      return false;
    }
  }
  
  bool FootstepGraph::projectStart()
  {
    unsigned int error_state;
    FootstepState::Ptr projected = projectFootstep(start_state_);
    if (projected) {
      start_state_ = projected;
      return true;
    }
    return false;
  }

  double footstepHeuristicZero(
    SolverNode<FootstepState, FootstepGraph>::Ptr node, FootstepGraph::Ptr graph)
  {
    return 0;
  }
  
  double footstepHeuristicStraight(
    SolverNode<FootstepState, FootstepGraph>::Ptr node, FootstepGraph::Ptr graph)
  {
    FootstepState::Ptr state = node->getState();
    FootstepState::Ptr goal = graph->getGoal(state->getLeg());
    Eigen::Vector3f state_pos(state->getPose().translation());
    Eigen::Vector3f goal_pos(goal->getPose().translation());
    return (std::abs((state_pos - goal_pos).norm() / graph->maxSuccessorDistance()));
  }
  
  double footstepHeuristicStraightRotation(
    SolverNode<FootstepState, FootstepGraph>::Ptr node, FootstepGraph::Ptr graph)
  {
    FootstepState::Ptr state = node->getState();
    FootstepState::Ptr goal = graph->getGoal(state->getLeg());
    Eigen::Affine3f transform = state->getPose().inverse() * goal->getPose();
    return (std::abs(transform.translation().norm() / graph->maxSuccessorDistance()) +
               std::abs(Eigen::AngleAxisf(transform.rotation()).angle()) / graph->maxSuccessorRotation());
  }

  double footstepHeuristicStepCost(
    SolverNode<FootstepState, FootstepGraph>::Ptr node, FootstepGraph::Ptr graph)
  {
    FootstepState::Ptr state = node->getState();
    FootstepState::Ptr goal = graph->getGoal(state->getLeg());
    Eigen::Vector3f diff_pos(goal->getPose().translation() - state->getPose().translation());
    Eigen::Quaternionf first_rot;
    // Eigen::Affine3f::rotation is too slow because it calls SVD decomposition
    first_rot.setFromTwoVectors(state->getPose().matrix().block<3, 3>(0, 0) * Eigen::Vector3f::UnitX(),
                                diff_pos);

    Eigen::Quaternionf second_rot;
    second_rot.setFromTwoVectors(diff_pos,
                                 goal->getPose().matrix().block<3, 3>(0, 0) * Eigen::Vector3f::UnitX());
    // is it correct??
    double first_theta = acos(first_rot.w()) * 2;
    double second_theta = acos(second_rot.w()) * 2;
    if (isnan(first_theta)) {
      first_theta = 0;
    }
    if (isnan(second_theta)) {
      second_theta = 0;
    }
    if (first_theta > M_PI) {
      first_theta = 2.0 * M_PI - first_theta;
    }
    if (second_theta > M_PI) {
      second_theta = 2.0 * M_PI - second_theta;
    }
    return (diff_pos.norm() / graph->maxSuccessorDistance()) +
      (first_theta + second_theta) / graph->maxSuccessorRotation();
  }

}
