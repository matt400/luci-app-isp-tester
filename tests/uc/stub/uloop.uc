'use strict';

/* stand-in for the router's uloop module: the unit tests only load the
 * collector's modules, they never start the loop */
function timer() { return { set: () => true, cancel: () => true }; }
function process() { return null; }
function handle() { return null; }

export { timer, process, handle };
