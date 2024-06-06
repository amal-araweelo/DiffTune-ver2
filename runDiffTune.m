% Use this script to 
% run the simulation with DiffTune

% Constant drive train parameters
% N: Gearing ratio
% J_m: Motor inertia
% J_l: Load inertia
% K_S: Shaft stifness
% D_s: Shaft damping coefficinet
% T_Cm: Motor Coulomb friction
% T_Sm: Motor static friction coefficient
% omega_s: Motor Stribeck velocity
% beta_m: Motor viscous friction coefficient

% Disturbances
% d_e: Input torque ripples and harmonics
% T_Fm: Motor friction
% T_Fl: Load friction
% T_l: Load torque

% States include
% omega_m: Motor angular velocity
% omega_l: Load angular velocity
% theta_m: motor angular position
% theta_l: load angular position
% X = [omega_m; omega_l; theta_m; theta_l]
% Xref (ini) = [omega_m; omega_l; theta_m; theta_r]

% Control includes
% Theta_r: Load postition reference
% Omega_r: Motor velocity reference
% u: Torque command

close all;
clear all;

addpath('mex\');
import casadi.*

%% define the dimensions
dim_state = 4; % dimension of system state
dim_control = 3;  % dimension of control inputs
dim_controllerParameters = 3;  % dimension of controller parameters

%% Video simulation
param.generateVideo = true;
if param.generateVideo
    video_obj = VideoWriter('DubinCar.mp4','MPEG-4');
    video_obj.FrameRate = 15;
    open(video_obj);
end

%% Define simulation parameters (e.g., sample time dt, duration, etc)
dt = 0.001;     % 1 kHz
time = 0:dt:10;

%% constant parameters
% omega_s: Motor Stribeck velocity
% Motor electrical parameters
param.r_s = 3.6644;           % Ohm -- Stator winding resistance (per phase)
param.L_d = 21.4e-3;          % mH -- Rotating field inductance
param.L_q = 1.2*param.L_d;          % mH -- Rotating torque inductance
param.P = 6;                  % Non-dimensional -- Number of poles
param.k_T = 1.43;             % Nm/A -- Torque constant
param.k_E = 87*2*pi*60*0.001; % Vs/rad -- Voltage constant
param.lambda_m = 0.3148;      % Vs/rad -- amplitude of the flux linkages
                        %   established by the permanent magnet as viewed
                        %   from the stator phase windings.
% Motor mechanical parameters
param.J_m = 2.81e-4 + 5.5e-4; % kgm^2 -- Moment of inertia
param.N = 1;                  % -- Gear ratio
% Values of friction and shaft parameters
% Taken from Table 4.3: Summary of calculated friction and shaft parameters
% (page 40, Dimitrios Papageorgiou phd thesis)
% Shaft constants
param.K_S = 32.94;    % N m rad^(-1)
param.D_S = 0.0548;   % N m s rad^(-1)
% Coulomb friction
% (assuming T_C is the average of T_C_m and T_C_l)
param.T_C = (0.0223 + 0.0232) / 2;    % N m
% Static friction
% (assuming T_S is the average of T_S_m and T_S_l)
param.T_S = (0.0441 + 0.0453) / 2;    % N m
% Friction constants
param.b_fr = 0.0016;  % N m s rad^(-1)
param.J_l = 1; % kgm^2 -- Moment of inertia
% Load inertia      (not sure...)
param.inv_J_l = param.J_l;

%% Initialize controller gains (must be a vector of size dim_controllerParameters x 1)
% STSMC (in nonlinear controller for omega_m)
k1 = 1.453488372 * 2.45 * 0.99; % use proportional gain from PI controller (k_vel = 1.45*2.45)
k2 = 50;
k_pos = 25;      % ignored when hand-tuning STSMC
k_vec = [k1; k2; k_pos];


%% Define desired trajectory if necessary
theta_r = sin(2*pi*time);   % theta_r is a sine wave with frequency 1 kHz
theta_r_dot = 2 * pi * cos(2*pi*time);


%% Initialize variables for DiffTune iterations
learningRate = 2;  % Calculate  
maxIterations = 100;
itr = 0;

loss_hist = [];  % storage of the loss value in each iteration
rmse_hist = []; % If we want video
param_hist = []; % storage of the parameter value in each iteration
gradientUpdate = zeros(dim_controllerParameters,1); % define the parameter update at each iteration

%% DiffTune iterations
while (1)
    itr = itr + 1;

    % Initialize state
    X_storage = zeros(dim_state,1);
    
    % Initialize sensitivity
    dx_dtheta = zeros(dim_state,dim_controllerParameters);
    du_dtheta = zeros(dim_control,dim_controllerParameters);

    % Initialize loss
    loss = 0;

    % Initialize gradient of loss
    theta_gradient = zeros(1,dim_controllerParameters);

    % Initialize reference state and desired trajectory
    Xref_storage = [X_storage(1:3) ; theta_r(1)];

    for k = 1 : length(time) - 1
       
        % Load current state and current reference
        X = X_storage(:,end);
        Xref = Xref_storage(:,end);
 
        % Compute the control action
        u = controller(X, Xref, k_vec, theta_r_dot(k), param.J_m, param.N, dt); 

        % Compute the sensitivity 
        [dx_dtheta, du_dtheta] = sensitivityComputation(sensitivity,X,Xref,theta_r_dot,u,param,k_vec,dt);
        
        % (loss is the squared norm of the position tracking error (error_theta = theta_r - theta_l))
        loss = loss + (norm(theta_r(k) - X(4)))^2;  % X(4) corresponds to current theta_l         

        % Accumulating the gradient of loss w/ respect to controller parameters
        % You need to provide dloss_dx and dloss_du here
        % dloss_dx = 2 * (X - Xref);  % gradient of loss function w/ respect to state (see notes)
        % dloss_du = 0;               % control input is not part of loss path (therefore loss does not depend directly on control input)
        % We then have:
        % theta_gradient = theta_gradient + dloss_dx * dx_dtheta;
        % Which can be written as (since we are only concerned with the position of load):
        theta_gradient = theta_gradient + 2 * [0 0 0 X(4) - Xref(4)] * dx_dtheta;

        % Integrate the ode dynamics
        [~, sold] = ode45(@(t,X) dynamics(t, X, u, param), [time(k) time(k+1)], X);
        
        % Store the new state
        X_storage = [X_storage sold(end,:)'];
        
    end

    % Compute the RSME (root-mean-square error)
    RMSE = sqrt(1 / length(time) * loss);

    % Store loss and RMSE
    loss_hist = [loss_hist loss];
    rmse_hist = [rmse_hist RMSE];

    % Update the gradient
    gradientUpdate = - learningRate * theta_gradient;

    % Sanity check
    if isnan(gradientUpdate)
       fprintf('gradient is NAN. Quit.\n');
       break;
    end
   
    % Gradient descent
    k_vec = k_vec + gradientUpdate';    % ' used for transposing matrix or vector

    % Projection of all parameters to the feasible set
    % the feasible set of parameters in this case is greater than 0.1
    % (taken from template)
    % (NEED TO FIND OUR VALUE!)
    if any(k_vec < 0.1)
       neg_indicator = (k_vec < 0.1);
       pos_indicator = ~neg_indicator;
       k_vec_default = 0.1 * ones(4,1);
       k_vec = neg_indicator.*k_vec_default + pos_indicator.*k_vec_default;
    end

    % Store the parameters
    param_hist = [param_hist k_vec];

    % Plotting
    set(gcf,'Position',[172 120 950 455]);
    set(gcf,'color','w');

    % Position (theta_l) tracking
    subplot(3,3,[1,2]);
    plot(t,X_storage(4,:),'DisplayName','actual','LineWidth',1.5);
    hold on;
    plot(t,Xref_storage(4,:),':','DisplayName','desired','LineWidth',1.5);
    xlabel('time [s]');
    ylabel('\theta_l [rad]');
    grid on;
    h_lgd = legend;
    set(h_lgd,'Position',[0.3811 0.8099 0.1097 0.0846],'FontSize',10);
    set(gca,'FontSize',10);

    % RMSE
    subplot(3,3,[3;6;9]);
    plot(rmse_history,'LineWidth',1.5);
    hold on;
    grid on;
    stem(length(rmse_history),rmse_history(end),'Color',[0 0.4470 0.7410]);

    xlim([0 100]);
    ylim([0 rmse_history(1)*1.1]);
    text(50,0.3,['iteration = ' num2str(length(rmse_history))],'FontSize',12);
    xlabel('iterations');
    ylabel('RMSE [rad]');
    set(gca,'FontSize',10);
    plotedit(gca,'on');
    plotedit(gca,'off');

    drawnow;

    % Visualization for movie
    if param.generateVideo
        frame = getframe(gcf);
        writeVideo(video_obj,frame);
        clf
    end

    % Terminate if the total number of iterations is more than maxIterations
    if itr >= maxIterations
       break;
    end
end

if param.generateVideo
    close(video_obj);
end

%% Plot trajectory
figure;
plot(time, Xref_storage(4,:),'DisplayName','theta_r');
hold on;
plot(time, X_storage(4,:),'DisplayName','theta_l');
legend;
ylabel('\theta [rad]');

%% Debug session
% check_dx_dtheta = sum(isnan(dx_dtheta),'all');
% check_du_dtheta = sum(isnan(du_dtheta),'all');
