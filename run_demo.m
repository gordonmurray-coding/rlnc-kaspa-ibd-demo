function run_demo()
% Convenience wrapper that ensures an output directory and runs the RLNC demo
if ~exist('results','dir'), mkdir results; end
rlnc_kaspa_ibd_demo();
disp('Done. Check the generated CSV files in the current folder (git-ignored results/ recommended).');
end
