import { Component, Fragment } from 'react';
import type { ErrorInfo, ReactNode } from 'react';
import { fetchNui } from '@/nui/bridge';

interface ErrorBoundaryProps {
  children: ReactNode;
}

interface ErrorBoundaryState {
  message: string | null;

  /** Bumped on dismiss, so the panel underneath is remounted clean rather than resumed broken. */
  generation: number;
}

/**
 * A render error inside the panel would otherwise leave a dead page holding NUI focus, with the
 * cursor trapped over a game nobody can reach. This catches it, says so, and its one button hands
 * focus back.
 */
export class ErrorBoundary extends Component<ErrorBoundaryProps, ErrorBoundaryState> {
  state: ErrorBoundaryState = { message: null, generation: 0 };

  static getDerivedStateFromError(error: unknown): Partial<ErrorBoundaryState> {
    return { message: error instanceof Error ? error.message : String(error) };
  }

  componentDidCatch(error: Error, info: ErrorInfo): void {
    console.error('[sd-gunracks] admin render error', error, info.componentStack);
  }

  private dismiss = (): void => {
    void fetchNui('admin:close');
    this.setState(prev => ({ message: null, generation: prev.generation + 1 }));
  };

  render(): ReactNode {
    if (this.state.message === null) {
      return <Fragment key={this.state.generation}>{this.props.children}</Fragment>;
    }

    return (
      <div className="ga-crash-root">
        <div className="ga-crash">
          <div className="ga-crash-title">Something broke</div>
          <p className="ga-crash-body">
            The admin panel hit an error and closed itself. Nothing you were doing was saved.
          </p>
          <p className="ga-crash-detail ga-mono">{this.state.message}</p>
          <button type="button" className="ga-crash-btn" onClick={this.dismiss} autoFocus>
            Close and give me back control
          </button>
        </div>
      </div>
    );
  }
}
