import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import App from './App';
import { isEnvBrowser } from './nui/bridge';
import './styles.css';

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);

if (isEnvBrowser()) {
  // Outside the game there is no Lua to open anything, so the dev server opens one surface
  // itself, against mock data, chosen by the query string:
  //
  //   /?admin             the staff console (also what a bare / opens)
  //   /?placer            the placer's strip, a wall rack being slid along a wall
  //   /?placer&floor      ... a floor rack, put somewhere it may not go
  //
  // One at a time, never together: the console is full-screen, and the one that loses the stacking
  // contest looks like a component that failed to render.
  void Promise.all([import('./nui/mock'), import('./admin/mock')]).then(([mock, adminMock]) => {
    const query = window.location.search;

    // A stand-in for the game behind the HUD pieces, so they are judged against something other
    // than white.
    document.body.style.background = 'radial-gradient(ellipse at 50% 40%, #5d6066 0%, #34363b 60%, #1a1b1e 100%)';

    if (query.includes('placer')) return mock.openMockPlacer(query.includes('floor'));
    adminMock.openMockAdmin();
  });
}
