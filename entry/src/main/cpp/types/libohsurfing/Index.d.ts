export interface AuthStatus {
  phase: string;
  detail: string;
  authenticated: boolean;
  running: boolean;
  connectedAt: number;
  logs: string[];
}

declare const bridge: {
  start(username: string, password: string): Promise<AuthStatus>;
  pulse(): Promise<AuthStatus>;
  stop(): Promise<AuthStatus>;
  status(): AuthStatus;
};
export default bridge;
