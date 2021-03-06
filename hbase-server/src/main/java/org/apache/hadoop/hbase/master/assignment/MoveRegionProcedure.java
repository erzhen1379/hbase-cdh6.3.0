/*
 *
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package org.apache.hadoop.hbase.master.assignment;

import java.io.IOException;

import org.apache.hadoop.hbase.HBaseIOException;
import org.apache.hadoop.hbase.ServerName;
import org.apache.hadoop.hbase.TableName;
import org.apache.hadoop.hbase.client.DoNotRetryRegionException;
import org.apache.hadoop.hbase.client.RegionInfo;
import org.apache.hadoop.hbase.master.RegionPlan;
import org.apache.hadoop.hbase.master.procedure.AbstractStateMachineRegionProcedure;
import org.apache.hadoop.hbase.master.procedure.MasterProcedureEnv;
import org.apache.hadoop.hbase.procedure2.ProcedureStateSerializer;
import org.apache.hadoop.hbase.shaded.protobuf.ProtobufUtil;
import org.apache.hadoop.hbase.shaded.protobuf.generated.MasterProcedureProtos.MoveRegionState;
import org.apache.hadoop.hbase.shaded.protobuf.generated.MasterProcedureProtos.MoveRegionStateData;
import org.apache.hbase.thirdparty.com.google.common.annotations.VisibleForTesting;
import org.apache.yetus.audience.InterfaceAudience;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Procedure that implements a RegionPlan.
 * It first runs an unassign subprocedure followed
 * by an assign subprocedure. It takes a lock on the region being moved.
 * It holds the lock for the life of the procedure.
 *
 * <p>Throws exception on construction if determines context hostile to move (cluster going
 * down or master is shutting down or table is disabled).</p>
 */
@InterfaceAudience.Private
public class MoveRegionProcedure extends AbstractStateMachineRegionProcedure<MoveRegionState> {
  private static final Logger LOG = LoggerFactory.getLogger(MoveRegionProcedure.class);
  private RegionPlan plan;

  public MoveRegionProcedure() {
    // Required by the Procedure framework to create the procedure on replay
    super();
  }

  @VisibleForTesting
  protected RegionPlan getPlan() {
    return this.plan;
  }

  /**
   * @param check whether we should do some checks in the constructor. We will skip the checks if we
   *          are reopening a region as this may fail the whole procedure and cause stuck. We will
   *          do the check later when actually executing the procedure so not a big problem.
   * @throws IOException If the cluster is offline or master is stopping or if table is disabled or
   *           non-existent.
   */
  public MoveRegionProcedure(MasterProcedureEnv env, RegionPlan plan, boolean check)
      throws HBaseIOException {
    super(env, plan.getRegionInfo());
    this.plan = plan;
    if (check) {
      preflightChecks(env, true);
      checkOnline(env, plan.getRegionInfo());
    }
  }

  @Override
  protected Flow executeFromState(final MasterProcedureEnv env, final MoveRegionState state)
      throws InterruptedException {
    LOG.trace("{} execute state={}", this, state);
    switch (state) {
      case MOVE_REGION_PREPARE:
        // Check context again and that region is online; do it here after we have lock on region.
        try {
          preflightChecks(env, true);
          checkOnline(env, this.plan.getRegionInfo());
          if (!env.getMasterServices().getServerManager().isServerOnline(this.plan.getSource())) {
            throw new HBaseIOException(this.plan.getSource() + " not online");
          }
        } catch (HBaseIOException e) {
          LOG.warn(this.toString() + " FAILED because " + e.toString());
          return Flow.NO_MORE_STATE;
        }
        break;
      case MOVE_REGION_UNASSIGN:
        try {
          checkOnline(env, this.plan.getRegionInfo());
        } catch (DoNotRetryRegionException dnrre) {
          LOG.info("Skipping move, {} is not online; {}", getRegion().getEncodedName(), this,
              dnrre);
          return Flow.NO_MORE_STATE;
        }
        addChildProcedure(new UnassignProcedure(plan.getRegionInfo(), plan.getSource(),
            plan.getDestination(), true));
        setNextState(MoveRegionState.MOVE_REGION_ASSIGN);
        break;
      case MOVE_REGION_ASSIGN:
        AssignProcedure assignProcedure = plan.getDestination() == null ?
            new AssignProcedure(plan.getRegionInfo()):
            new AssignProcedure(plan.getRegionInfo(), plan.getDestination());
        addChildProcedure(assignProcedure);
        return Flow.NO_MORE_STATE;
      default:
        throw new UnsupportedOperationException("unhandled state=" + state);
    }
    return Flow.HAS_MORE_STATE;
  }

  @Override
  protected void rollbackState(final MasterProcedureEnv env, final MoveRegionState state)
      throws IOException {
    // no-op
  }

  @Override
  public boolean abort(final MasterProcedureEnv env) {
    return false;
  }

  @Override
  public void toStringClassDetails(final StringBuilder sb) {
    sb.append(getClass().getSimpleName());
    sb.append(" ");
    sb.append(plan);
  }

  @Override
  protected MoveRegionState getInitialState() {
    return MoveRegionState.MOVE_REGION_UNASSIGN;
  }

  @Override
  protected int getStateId(final MoveRegionState state) {
    return state.getNumber();
  }

  @Override
  protected MoveRegionState getState(final int stateId) {
    return MoveRegionState.forNumber(stateId);
  }

  @Override
  public TableName getTableName() {
    return plan.getRegionInfo().getTable();
  }

  @Override
  public TableOperationType getTableOperationType() {
    return TableOperationType.REGION_EDIT;
  }

  @Override
  protected void serializeStateData(ProcedureStateSerializer serializer)
      throws IOException {
    super.serializeStateData(serializer);

    final MoveRegionStateData.Builder state = MoveRegionStateData.newBuilder()
        // No need to serialize the RegionInfo. The super class has the region.
        .setSourceServer(ProtobufUtil.toServerName(plan.getSource()));
    if (plan.getDestination() != null) {
      state.setDestinationServer(ProtobufUtil.toServerName(plan.getDestination()));
    }

    serializer.serialize(state.build());
  }

  @Override
  protected void deserializeStateData(ProcedureStateSerializer serializer)
      throws IOException {
    super.deserializeStateData(serializer);

    final MoveRegionStateData state = serializer.deserialize(MoveRegionStateData.class);
    final RegionInfo regionInfo = getRegion(); // Get it from super class deserialization.
    final ServerName sourceServer = ProtobufUtil.toServerName(state.getSourceServer());
    final ServerName destinationServer = state.hasDestinationServer() ?
        ProtobufUtil.toServerName(state.getDestinationServer()) : null;
    this.plan = new RegionPlan(regionInfo, sourceServer, destinationServer);
  }

  @Override
  protected boolean waitInitialized(MasterProcedureEnv env) {

    if (TableName.isMetaTableName(getTableName())) {
      // only offline state master will try init meta procedure
      return false;
    }

    if (getTableName().equals(TableName.NAMESPACE_TABLE_NAME)) {
      //  after unassign procedure finished, namespace region will be offline
      //  if master crashed at the same time and reboot
      //  it will be stuck as master init is block by  waiting namespace table online
      //  but move region procedure can not go on, break the deadlock by not wait master initialized
      return false;
    }
    return super.waitInitialized(env);
  }
}
