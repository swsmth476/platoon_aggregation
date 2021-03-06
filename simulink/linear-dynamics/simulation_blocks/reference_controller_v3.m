function reference_controller_v3(block)

  setup(block);
  
%endfunction

function setup(block)
  
  %% Register number of dialog parameters   
  block.NumDialogPrms = 0;

  %% Register number of input and output ports
  block.NumInputPorts  = 2;
  block.NumOutputPorts = 1;

  %% Setup functional port properties to dynamically
  %% inherited.
  block.SetPreCompInpPortInfoToDynamic;
  block.SetPreCompOutPortInfoToDynamic;
 
  block.InputPort(1).Dimensions        = 6;
  block.InputPort(1).DirectFeedthrough = false;
  
  block.InputPort(2).Dimensions        = 1;
  block.InputPort(2).DirectFeedthrough = false;

  block.OutputPort(1).Dimensions       = 2;
  
  %% Set block sample time to inherited
  block.SampleTimes = [-1 0];
  
  %% Set the block simStateCompliance to default (i.e., same as a built-in block)
  block.SimStateCompliance = 'DefaultSimState';

  %% Register methods
  block.RegBlockMethod('InitializeConditions',     @InitConditions);  
  block.RegBlockMethod('Outputs',                  @Output);
  
%endfunction

function InitConditions(block) 
  block.OutputPort(1).Data = [0; 0];
  
%endfunction

function Output(block)
  global mdl;

  % model predictive controller for reference model %
  
  zt = block.InputPort(1).Data;
  time = block.InputPort(2).Data;
  
  if(isnan(zt(5)) || isnan(zt(6)))
      % to get rid of simulation initialization error
      zt(5) = 0;
      zt(6) = 0;
  end
  
  % in order to fix weird initialization bug
  if(zt == zeros(6,1))
      zt = [mdl.z0; zeros(2,1)]; % set to initial state
  end
  
  % find time step index
  dt = 0.1;
  time_step = floor(time/dt);
  
  % get current velocities
  v1 = zt(2);
  v2 = zt(4);
  
  % use current velocity
  syms va vb;
  % Ad = double(subs(mdl.Ad, [va vb], [v1 v2]));
  % Bd = double(subs(mdl.Bd, [va vb], [v1 v2]));
  % Kd = double(subs(mdl.Kd, [va vb], [v1 v2])); % linearize around v
  % don't need to linearize around v now (drag term removed)
  Ad = mdl.Ad;
  Bd = mdl.Bd;
  Kd = mdl.Kd;
  
  % create augmented system dynamics
  A = [[Ad Bd]; zeros(2,4) eye(2)];
  B = [zeros(4,2); eye(2)];
  theta = [Kd; zeros(2,1)];
  
  % event trigger time (when the platoon is told to accelerate / increase
  % headway)
  event_trigger = 20; % (begin at 2s)
  
  % choose augmented system state/input costs
  % want to minimize (xa - xb - dist_des)^2
  % Qf = zeros(6);
  Qf = [1  0 -1  0  0  0;
       0  0  0  0  0  0;
       -1  0  1  0  0  0;
       0  0  0  0  0  0;
       0  0  0  0  0  0;
       0  0  0  0  0  0];
  dist_des = 24; % desired final distance between the platoons
  % qf = zeros(6,1);
  qf = [-dist_des; 0; dist_des; 0; 0; 0];
  % add tuning gain here
  if(time_step < event_trigger)
      gain2 = 0;
  else
      gain2 = 0.65;
  end
  Qf = gain2 * Qf;
  qf = gain2 * qf;
  % Q = zeros(6);
  Q = diag([0; 0; 0; 0; 1; 1]);
  % adding tuning gain here
  gain = 1.0;
  Q = gain * Q + Qf;
  q = zeros(6,1) + qf;
  gain3 = 0.05;
  R = gain3 * eye(2);
  % R = zeros(2);
  r = zeros(2,1);
  
  % headway constraints
  headway_lb = 20;
  
  % velocity constraints
  velocity_lb = 24;
  velocity_ub = 32;
  
  % acceleration constraints
  accel_ub = 3;
  accel_lb = -3;
  
  % jerk constraints
  j_ub = 1.0;
  j_lb = -1.0;
  
  % MPC parameters %
  T = mdl.mpc_H; % planning horizon
  x0 = zt;
  
  %%% SYSTEM_CONSTRAINTS %%%
  constraints = [];
  n = size(x0,1); % state dimension
  m = size(B,2); % input dimension
  x_bar = []; % x = [x(t+1); x(t+2); ... x(t+T)]
  u_bar = []; % u = [u(t); u(t+1); ... u(t+T-1)] (both col vectors)

  % create state decision variables for each time index
  for i = 1:T
    x{i} = sdpvar(n,1);
    u{i} = sdpvar(m,1);
    x_bar = [x_bar; x{i}];
    u_bar = [u_bar; u{i}];
  end

  % require that system updates satisfy x(t+1) = Ax(t) + Bu(t) + theta
  [G, L] = make_sys_constr(T, A, B, theta, x0);
  constraints = [constraints, x_bar <= G*u_bar + L];
  constraints = [constraints, x_bar >= G*u_bar + L];
  
  %%% STATE_CONSTRAINTS %%%
  Hx = [-1  0  1  0  0  0;  % headway lb
         0 -1  0  0  0  0;  % velocity lb
         0  1  0  0  0  0;  % velocity ub
         0  0  0 -1  0  0;  % velocity lb
         0  0  0  1  0  0;  % velocity ub
         0  0  0  0 -1  0;  % accel lb
         0  0  0  0  1  0;  % accel ub
         0  0  0  0  0 -1;  % accel lb
         0  0  0  0  0  1]; % accel ub
  hx = [-headway_lb; -velocity_lb; velocity_ub; -velocity_lb; velocity_ub;
        -accel_lb; accel_ub; -accel_lb; accel_ub];
  [Hx_bar, hx_bar] = make_state_constr(T, Hx, hx);
  constraints = [constraints, Hx_bar*x_bar <= hx_bar];

  %%% INPUT_CONSTRAINTS %%%
  % input constraints
  Hu = [eye(2); -eye(2)];
  hu = [j_ub; j_ub; -j_lb; -j_lb];
  % require that inputs satisfy Hu*u(t) <= hu for all t
  [Hu_bar, hu_bar] = make_input_constr(T, Hu, hu);
  constraints = [constraints, Hu_bar*u_bar <= hu_bar];
  
  %%% OBJECTIVE_FUNCTION %%%
  [Q_bar, q_bar, R_bar, r_bar] = make_QP_costs(T,Q,Qf,q,qf,R,r);
  obj_fun = 1/2*(x_bar'*Q_bar*x_bar + u_bar'*R_bar*u_bar) + ...
                q_bar'*x_bar + r_bar'*u_bar;

  %%% CALL SOLVER %%%
  optimize(constraints, obj_fun, sdpsettings('solver','quadprog'));
  u_opt = value(u_bar);
  delta_v = u_opt(1:2);
    
  % implement input on system
  v = zt(5:6);
  block.OutputPort(1).Data = v + delta_v;

%endfunction
