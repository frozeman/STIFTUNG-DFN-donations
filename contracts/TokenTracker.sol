/*
The MIT License (MIT)

Copyright (c) 2016 DFINITY Stiftung 

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

/**
 * @title:  A contract that tracks numbers of tokens assigned to addresses. 
 * @author: Timo Hanke <timo.t.hanke@gmail.com> 
 *
 * Optionally, assignments can be chosen to be of "restricted type". 
 * Being "restricted" means that the token assignment may later be partially
 * reverted (or the tokens "burned") by the contract. 
 *
 * After all token assignments are completed the contract
 *   - burns some restricted tokens
 *   - releases the restriction on the remaining tokens
 * The percentage of tokens that burned out of each assignment of restricted
 * tokens is calculated to achieve the following condition:
 *   - the remaining formerly restricted tokens combined have a pre-configured
 *     share (percentage) among all remaining tokens.
 *
 * Once the conversion process has started the contract enters a state in which
 * no more assignments can be made.
 */
 
pragma solidity ^0.4.6;

contract TokenTracker {
  // Share of formerly restricted tokens among all tokens in percent 
  uint public restrictedShare; 

  // Mapping from address to number of tokens assigned to the address
  mapping(address => uint) public tokens;

  // Mapping from address to number of tokens assigned to the address that
  // underly a restriction
  mapping(address => uint) public restrictions;
  
  // Total number of (un)restricted tokens currently in existence
  uint public totalRestrictedTokens; 
  uint public totalUnrestrictedTokens; 
  
  // Total number of individual assignment calls have been for (un)restricted
  // tokens
  uint public totalRestrictedAssignments; 
  uint public totalUnrestrictedAssignments; 

  // State flag. Assignments can only be made if false. 
  // Starting the conversion (burn) process irreversibly sets this to true. 
  bool public assignmentsClosed = false;
  
  // The multiplier (defined by nominator and denominator) that defines the
  // fraction of all restricted tokens to be burned. 
  // This is computed after assignments have ended and before the conversion
  // process starts.
  uint public burnMultDen;
  uint public burnMultNom;

  function TokenTracker(uint _restrictedShare) {
    // Throw if restricted share >= 100
    if (_restrictedShare >= 100) { throw; }
    
    restrictedShare = _restrictedShare;
  }
  
  /** 
   * PUBLIC functions
   *
   *  - isUnrestricted (getter)
   *  - multFracCeiling (library function)
   *  - isRegistered(addr) (getter)
   */
  
  /**
   * Return true iff the assignments are closed and there are no restricted
   * tokens left 
   */
  function isUnrestricted() constant returns (bool) {
    return (assignmentsClosed && totalRestrictedTokens == 0);
  }

  /**
   * Return the ceiling of (x*a)/b
   *
   * Edge cases:
   *   a = 0: return 0
   *   b = 0, a != 0: error (solidity throws on division by 0)
   */
  function multFracCeiling(uint x, uint a, uint b) returns (uint) {
    // Catch the case a = 0
    if (a == 0) { return 0; }
    
    // Rounding up is the same as adding 1-epsilon and rounding down.
    // 1-epsilon is modeled as (b-1)/b below.
    return (x * a + (b - 1)) / b; 
  }
    
  /**
   * Return true iff the address has tokens assigned (resp. restricted tokens)
   */
  function isRegistered(address addr, bool restricted) constant returns (bool) {
    if (restricted) {
      return (restrictions[addr] > 0);
    } else {
      return (tokens[addr] > 0);
    }
  }

  /**
   * INTERNAL functions
   *
   *  - assign
   *  - closeAssignments 
   *  - unrestrict 
   */
   
  /**
   * Assign (un)restricted tokens to given address
   */
  function assign(address addr, uint tokenAmount, bool restricted) internal {
    // Throw if assignments have been closed
    if (assignmentsClosed) { throw; }

    // Assign tokens
    tokens[addr] += tokenAmount;

    // Record restrictions and update total counters
    if (restricted) {
      totalRestrictedTokens += tokenAmount;
      totalRestrictedAssignments += 1;
      restrictions[addr] += tokenAmount;
    } else {
      totalUnrestrictedTokens += tokenAmount;
      totalUnrestrictedAssignments += 1;
    }
  }

  /**
   * Close future assignments.
   *
   * This is irreversible and closes all future assignments.
   * The function can only be called once.
   *
   * A call triggers the calculation of what fraction of restricted tokens
   * should be burned by subsequent calls to the unrestrict() function.
   * The result of this calculation is a multiplication factor whose nominator
   * and denominator are stored in the contract variables burnMultNom,
   * burnMultDen.
   */
  function closeAssignmentsIfOpen() internal {
    // Return if assignments are not open
    if (assignmentsClosed) { return; } 
    
    // Set the state to "closed"
    assignmentsClosed = true;

    /*
     *  Calculate the total number of tokens that should remain after
     *  conversion.  This is based on the total number of unrestricted tokens
     *  assigned so far and the pre-configured share that the remaining
     *  formerly restricted tokens should have.
     */
    uint totalTokensTarget = (totalUnrestrictedTokens * 100) / 
      (100 - restrictedShare);
    
    // The total number of tokens in existence now.
    uint totalTokensExisting = totalRestrictedTokens + totalUnrestrictedTokens;
      
    /*
     * The total number of tokens that need to be burned to bring the existing
     * number down to the target number. If the existing number is lower than
     * the target then we won't burn anything.
     */
    uint totalBurn = 0; 
    if (totalTokensExisting > totalTokensTarget) {
      totalBurn = totalTokensExisting - totalTokensTarget; 
    }

    // The fraction of restricted tokens to be burned (by nominator and
    // denominator).
    burnMultNom = totalBurn;
    burnMultDen = totalRestrictedTokens;
    
    /*
     * For verifying the correctness of the above calculation it may help to
     * note the following.
     * Given 0 <= restrictedShare < 100, we have:
     *  - totalTokensTarget >= totalUnrestrictedTokens
     *  - totalTokensExisting <= totalRestrictedTokens + totalTokensTarget
     *  - totalBurn <= totalRestrictedTokens
     *  - burnMultNom <= burnMultDen
     * Also note that burnMultDen = 0 means totalRestrictedTokens = 0, in which
     * burnMultNom = 0 as well.
     */
  }

  /**
   * Unrestrict (convert) all restricted tokens assigned to the given address
   *
   * This function can only be called after assignments have been closed via
   * closeAssignments().
   * The return value is the number of restricted tokens that were burned in
   * the conversion.
   */
  function unrestrict(address addr) internal returns (uint) {
    // Throw is assignments are not yet closed
    if (!assignmentsClosed) { throw; }

    // The balance of restricted tokens for the given address 
    uint restrictionsForAddr = restrictions[addr];
    
    // Throw if there are none
    if (restrictionsForAddr == 0) { throw; }

    // Apply the burn multiplier to the balance of restricted tokens
    // The result is the ceiling of the value: 
    // (restrictionForAddr * burnMultNom) / burnMultDen
    uint burn = multFracCeiling(restrictionsForAddr, burnMultNom, burnMultDen);

    // Remove the tokens to be burned from the address's balance
    tokens[addr] -= burn;
    
    // Delete record of restrictions 
    delete restrictions[addr];
    
    // Update the counters for total (un)restricted tokens
    totalRestrictedTokens   -= restrictionsForAddr;
    totalUnrestrictedTokens += restrictionsForAddr - burn;
      
    return burn;
  }
}
